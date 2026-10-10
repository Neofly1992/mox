import Foundation
import MoxDomain
import OSLog

/// Durable library mutations and one owned download lifecycle. Catalog history
/// stays in the repository; only the executing operation is retained in memory.
public actor DownloadManager {
  private let persistence: any ModelLibraryPersistence
  private let artifacts: ArtifactStore
  private let verifier: any CommittedArtifactVerifying
  private let verificationSession = UUID()
  private struct Verification {
    let task: Task<ModelInstallation, Error>
    let wait: SharedVerificationWait<ModelInstallation>
  }
  private var verifications: [UUID: Verification] = [:]
  private var recoveryTask: Task<Void, Never>?
  private var recoveryState = LibraryRecoveryState()
  private static let maximumConcurrentVerifications = 2
  private var runners: [UUID: Task<Void, Never>] = [:]
  private var stopping = false
  private var lifecycleOwner: UUID?
  private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
  private var failedTerminalSaves: [UUID: DownloadOperation] = [:]
  init(
    persistence: any ModelLibraryPersistence, artifacts: ArtifactStore,
    verifier: any CommittedArtifactVerifying = CommittedArtifactVerifier()
  ) {
    self.persistence = persistence
    self.artifacts = artifacts
    self.verifier = verifier
  }
  public static func open(
    persistence: any ModelLibraryPersistence, artifacts: ArtifactStore,
    verifier: any CommittedArtifactVerifying = CommittedArtifactVerifier()
  )
    async throws -> DownloadManager
  {
    let manager = DownloadManager(
      persistence: persistence, artifacts: artifacts, verifier: verifier)
    await manager.startRecovery()
    return manager
  }
  private func startRecovery() {
    recoveryState = .init(phase: .recovering)
    recoveryTask = Task {
      do {
        try await self.recover()
        self.recoveryState.phase = self.stopping ? .stopping : .ready
      } catch is CancellationError {
        self.recoveryState.phase = .stopping
      } catch {
        self.recoveryState.phase = self.stopping ? .stopping : .failed
        self.recoveryState.errorCode = (error as? MoxError)?.code.rawValue ?? "storageFailed"
        Logger(subsystem: "dev.mox", category: "storage").error("stage=recovery code=storageFailed")
      }
    }
  }
  public func recoveryStatus() -> LibraryRecoveryState { recoveryState }
  public func waitForRecovery() async { await recoveryTask?.value }
  private func presented(_ item: ModelInstallation) -> ModelInstallation {
    var item = item
    if item.manifest != nil, item.availability == .ready,
      item.verificationSession != verificationSession
    {
      item.availability = .checking
    }
    return item
  }
  private func presented(_ summary: ModelInstallationSummary) -> ModelInstallationSummary {
    var summary = summary
    if summary.origin != nil, summary.availability == .ready,
      summary.verificationSession != verificationSession
    {
      summary.availability = .checking
    }
    return summary
  }
  /// Only this process's successful integrity verification authorizes inference.
  /// One background and one on-demand model can make progress independently.
  public func verifyInstallation(_ id: UUID) async throws -> ModelInstallation {
    guard !stopping else { throw MoxError(.shuttingDown, "Library is stopping.") }
    let original = try await installation(id)
    guard !original.deletionPending else { throw MoxError(.busy, "Model removal is pending.") }
    guard let manifest = original.manifest else {
      try validateExternalReference(path: original.path)
      return original
    }
    let directory = try artifacts.installedDirectory(for: manifest.origin)
    let expectedPath =
      manifest.origin.variant.isEmpty
      ? directory.path : directory.appendingPathComponent(manifest.origin.variant).path
    guard original.path == expectedPath else {
      throw MoxError(.invalidModel, "Managed model path does not match its artifact identity.")
    }
    if original.verificationSession == verificationSession, original.availability == .ready {
      return original
    }
    if let existing = verifications[id] { return try await existing.wait.value() }
    guard verifications.count < Self.maximumConcurrentVerifications else {
      throw MoxError(.busy, "Model verification capacity is busy; retry shortly.")
    }
    let task = Task {
      defer { self.verifications[id] = nil }
      return try await self.performVerification(id, manifest: manifest)
    }
    let wait = SharedVerificationWait(task)
    verifications[id] = Verification(task: task, wait: wait)
    return try await wait.value()
  }
  /// Full committed-artifact inspection without updating recovery/index state.
  func inspectInstallationReadOnly(_ item: ModelInstallation) async throws {
    guard let manifest = item.manifest else { return }
    let directory = try artifacts.installedDirectory(for: manifest.origin)
    let expectedPath = manifest.origin.variant.isEmpty
      ? directory.path : directory.appendingPathComponent(manifest.origin.variant).path
    guard item.path == expectedPath else {
      throw MoxError(.invalidModel, "Managed model path does not match its artifact identity.")
    }
    let actual = try await verifier.inspect(manifest.origin, in: artifacts)
    try Task.checkCancellation()
    guard actual == manifest else {
      throw MoxError(.invalidModel, "Installed manifest differs from its index.")
    }
  }
  private func performVerification(_ id: UUID, manifest: ArtifactManifest) async throws
    -> ModelInstallation
  {
    var bytesVerified = false
    do {
      let actual = try await verifier.inspect(manifest.origin, in: artifacts)
      try Task.checkCancellation()
      guard actual == manifest else {
        throw MoxError(.invalidModel, "Installed manifest differs from its index.")
      }
      bytesVerified = true
      await acquireMutation()
      defer { releaseMutation() }
      var current = try await installation(id)
      guard !current.deletionPending, !stopping else {
        throw MoxError(.shuttingDown, "Installation changed while verifying.")
      }
      current.availability = .ready
      current.verificationSession = verificationSession
      try await persistence.commit(.init(installations: [current]))
      return current
    } catch {
      if !bytesVerified, !(error is CancellationError), !stopping {
        await acquireMutation()
        if var current = try? await persistence.installation(.id(id)) {
          current.availability = .corrupt
          do { try await persistence.commit(.init(installations: [current])) } catch {
            releaseMutation()
            throw error
          }
        }
        releaseMutation()
      }
      throw error
    }
  }
  private func verifyForRecovery(_ id: UUID) async throws {
    while true {
      try Task.checkCancellation()
      do {
        _ = try await verifyInstallation(id)
        return
      } catch let error as MoxError where error.code == .busy && !verifications.isEmpty {
        // Foreground verification may temporarily occupy both IO slots.
        // Await owned work rather than skip an unchecked entry or spin.
        if let pending = verifications.values.first?.task { _ = try? await pending.value }
        await Task.yield()
      }
    }
  }
  private func acquireMutation() async {
    while mutationInProgress { await withCheckedContinuation { mutationWaiters.append($0) } }
    mutationInProgress = true
  }
  private func releaseMutation() {
    mutationInProgress = false
    let waiters = mutationWaiters
    mutationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
  private func acquireLifecycle(_ id: UUID) async {
    while lifecycleOwner != nil { await withCheckedContinuation { lifecycleWaiters.append($0) } }
    lifecycleOwner = id
  }
  private func releaseLifecycle() {
    lifecycleOwner = nil
    let waiters = lifecycleWaiters
    lifecycleWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
  public func configuration() async throws -> ModelConfiguration {
    try await persistence.configuration()
  }
  public func installation(_ id: UUID) async throws -> ModelInstallation {
    guard let item = try await persistence.installation(.id(id)) else {
      throw MoxError(.notFound, "Model installation was not found.")
    }
    return presented(item)
  }
  public func findInstallation(_ lookup: InstallationLookup) async throws -> ModelInstallation? {
    try await persistence.installation(lookup).map { presented($0) }
  }
  private func aliasDoesNotUseInstallationID(_ alias: String) async throws -> Bool {
    guard let id = UUID(uuidString: alias) else { return true }
    return try await persistence.installation(.id(id)) == nil
  }
  public func findInstalled(identifier: String) async throws -> ModelInstallation? {
    let alias = try await persistence.installation(.alias(identifier))
    guard let id = UUID(uuidString: identifier) else { return alias }
    let byID = try await persistence.installation(.id(id))
    if let alias, let byID, alias.id != byID.id {
      throw MoxError(.busy, "Model identifier conflicts with another installation alias.")
    }
    return (alias ?? byID).map { presented($0) }
  }
  public func operation(_ id: UUID) async throws -> DownloadOperation {
    if let failed = failedTerminalSaves[id] { return failed }
    guard let operation = try await persistence.operation(id) else {
      throw MoxError(.notFound, "Download operation was not found.")
    }
    return operation
  }
  public func installations(offset: Int, limit: Int = 100) async throws -> [ModelInstallation] {
    try await persistence.installations(offset: offset, limit: limit)
  }
  public func operations(offset: Int, limit: Int = 100) async throws -> [DownloadOperation] {
    try await persistence.operations(offset: offset, limit: limit).map {
      failedTerminalSaves[$0.id] ?? $0
    }
  }
  public func installationSummaries(offset: Int, limit: Int = 100) async throws
    -> [ModelInstallationSummary]
  {
    try await persistence.installationSummaries(offset: offset, limit: limit).map { presented($0) }
  }
  public func operationSummaries(offset: Int, limit: Int = 100) async throws
    -> [DownloadOperationSummary]
  {
    try await persistence.operationSummaries(offset: offset, limit: limit).map { item in
      failedTerminalSaves[item.id].map(DownloadOperationSummary.init) ?? item
    }
  }
  public func diagnosticOperations() async throws -> [DownloadOperationSummary] {
    let count = try await persistence.operationCount()
    var offset = max(0, count - 256)
    var summaries: [DownloadOperationSummary] = []
    while offset < count {
      let page = try await operationSummaries(offset: offset)
      if page.isEmpty { break }
      summaries += page
      offset += page.count
    }
    for id in Set(runners.keys).union(failedTerminalSaves.keys)
    where !summaries.contains(where: { $0.id == id }) {
      summaries.append(DownloadOperationSummary(try await operation(id)))
    }
    return summaries
  }
  public func activeOperationCount() async throws -> Int {
    let persisted = try await persistence.activeOperationCount()
    return max(0, persisted - failedTerminalSaves.count)
  }
  public func page(installationOffset: Int = 0, operationOffset: Int = 0) async throws
    -> ModelLibraryPage
  {
    await acquireMutation()
    defer { releaseMutation() }
    return try await ModelLibraryPage(
      configuration: persistence.configuration(),
      installations: installationSummaries(
        offset: installationOffset, limit: ModelLibraryPage.pageSize),
      operations: operationSummaries(offset: operationOffset, limit: ModelLibraryPage.pageSize),
      installationOffset: installationOffset, operationOffset: operationOffset,
      totalInstallations: persistence.installationCount(),
      totalOperations: persistence.operationCount())
  }
  public func registry(_ id: UUID) async throws -> ModelRegistry {
    guard let registry = try await configuration().registries.first(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Model source is not configured.")
    }
    return registry
  }
  private func changeConfiguration(
    expectedRevision: UInt64? = nil,
    _ change: (inout ModelConfiguration) throws -> Void
  ) async throws -> ModelConfiguration {
    await acquireMutation()
    defer { releaseMutation() }
    var configuration = try await persistence.configuration()
    if let expectedRevision, expectedRevision != configuration.revision {
      throw MoxError(.busy, "Configuration changed; reload and try again.")
    }
    try change(&configuration)
    configuration.revision += 1
    try await persistence.commit(.init(configuration: configuration))
    return configuration
  }
  public func setDefaultRegistry(_ id: UUID, expectedRevision: UInt64) async throws
    -> ModelConfiguration
  {
    try await changeConfiguration(expectedRevision: expectedRevision) { configuration in
      guard configuration.registries.contains(where: { $0.id == id }) else {
        throw MoxError(.notFound, "Default source must be configured first.")
      }
      configuration.defaultRegistryID = id
      configuration.defaultProvenance = .user
    }
  }
  public func setPublicAPIEnabled(_ enabled: Bool) async throws -> ModelConfiguration {
    try await changeConfiguration { $0.publicAPIEnabled = enabled }
  }
  public func setGlobalSampling(_ settings: SamplingSettings, expectedRevision: UInt64) async throws
    -> ModelConfiguration
  {
    try settings.validate()
    return try await changeConfiguration(expectedRevision: expectedRevision) {
      $0.globalSampling = settings
    }
  }
  private func changeInstallation(
    _ id: UUID, expectedRevision: UInt64,
    _ change: (inout ModelInstallation) -> Void
  ) async throws -> ModelInstallation {
    await acquireMutation()
    defer { releaseMutation() }
    var configuration = try await persistence.configuration()
    guard configuration.revision == expectedRevision else {
      throw MoxError(.busy, "Configuration changed; reload and try again.")
    }
    var item = try await installation(id)
    guard !item.deletionPending else { throw MoxError(.busy, "Model removal is in progress.") }
    change(&item)
    configuration.revision += 1
    try await persistence.commit(.init(configuration: configuration, installations: [item]))
    return item
  }
  public func setModelSampling(_ id: UUID, settings: SamplingSettings, expectedRevision: UInt64)
    async throws -> ModelInstallation
  {
    try settings.validate()
    return try await changeInstallation(id, expectedRevision: expectedRevision) {
      $0.samplingSettings = settings
    }
  }
  func setPinned(_ id: UUID, pinned: Bool, expectedRevision: UInt64) async throws
    -> ModelInstallation
  {
    try await changeInstallation(id, expectedRevision: expectedRevision) { $0.pinned = pinned }
  }
  func updateRegistry(_ registry: ModelRegistry, expectedRevision: UInt64) async throws
    -> ModelConfiguration
  {
    guard registry.name.utf8.count <= 128, registry.origin.absoluteString.utf8.count <= 2048,
      (registry.mirror?.absoluteString.utf8.count ?? 0) <= 2048
    else {
      throw MoxError(.invalidParameters, "Model source settings exceed their size limit.")
    }
    return try await changeConfiguration(expectedRevision: expectedRevision) { configuration in
      if let index = configuration.registries.firstIndex(where: { $0.id == registry.id }) {
        configuration.registries[index] = registry
      } else {
        configuration.registries.append(registry)
      }
      guard configuration.registries.count <= 32 else {
        throw MoxError(.resourceLimit, "Model source count exceeds 32.")
      }
    }
  }
  func validateExternalReference(path: String) throws {
    let managed = artifacts.root.appendingPathComponent("artifacts").path
    guard path != managed, !path.hasPrefix(managed + "/") else {
      throw MoxError(
        .invalidModel, "Managed artifact must finish indexing and verification before use.")
    }
  }
  public func importDirectory(path: String, alias: String) async throws -> ModelInstallation {
    await acquireMutation()
    defer { releaseMutation() }
    let model = try LocalModel(path: path)
    if let item = try await persistence.installation(.path(model.directory.path)) {
      return presented(item)
    }
    try validateExternalReference(path: model.directory.path)
    guard !alias.isEmpty, !alias.hasPrefix(ArtifactOrigin.aliasPrefix), alias.utf8.count <= 256,
      try await persistence.installation(.alias(alias)) == nil,
      try await aliasDoesNotUseInstallationID(alias)
    else { throw MoxError(.busy, "Model alias is empty or already in use.") }
    let item = ModelInstallation(path: model.directory.path, manifest: nil, alias: alias)
    guard try await persistence.installation(.alias(item.id.uuidString)) == nil,
      try await persistence.installation(.id(item.id)) == nil
    else {
      throw MoxError(.busy, "Generated installation ID conflicts with an alias; retry import.")
    }
    try await persistence.commit(.init(installations: [item]))
    return item
  }
  private func installationChanges(_ manifest: ArtifactManifest, path: String) async throws
    -> [ModelInstallation]
  {
    let alias = manifest.origin.preferredAlias
    var changed: [ModelInstallation] = []
    if var previous = try await persistence.installation(.alias(alias)) {
      guard let origin = previous.manifest?.origin, origin.registryID == manifest.origin.registryID,
        origin.repository == manifest.origin.repository, origin.variant == manifest.origin.variant
      else {
        throw MoxError(.busy, "A local reference already uses the model alias.")
      }
      previous.alias = origin.fixedAlias
      changed.append(previous)
    }
    let item = ModelInstallation(path: path, manifest: manifest, alias: alias)
    guard try await persistence.installation(.alias(item.id.uuidString)) == nil,
      try await persistence.installation(.id(item.id)) == nil
    else {
      throw MoxError(
        .busy, "Generated installation ID conflicts with an existing identifier; retry.")
    }
    changed.append(item)
    return changed
  }
  public func selectInstallation(_ id: UUID) async throws {
    await acquireMutation()
    defer { releaseMutation() }
    var selected = try await installation(id)
    guard let manifest = selected.manifest,
      selected.availability == .ready || selected.availability == .checking
    else {
      throw MoxError(.invalidModel, "Only an available managed model can be selected.")
    }
    _ = try LocalModel(path: selected.path)
    var changed: [ModelInstallation] = []
    if var old = try await persistence.installation(.alias(manifest.origin.preferredAlias)),
      old.id != id
    {
      guard let origin = old.manifest?.origin else {
        throw MoxError(.storageFailed, "Model alias points to an external reference.")
      }
      old.alias = origin.fixedAlias
      changed.append(old)
    }
    selected.alias = manifest.origin.preferredAlias
    changed.append(selected)
    try await persistence.commit(.init(installations: changed))
  }
  private func removalChanges(_ item: ModelInstallation) async throws -> LibraryChanges {
    var changes = LibraryChanges(removedInstallations: [item.id])
    guard let origin = item.manifest?.origin else { return changes }
    var operationOffset = 0
    while true {
      let page = try await persistence.operations(origin: origin, offset: operationOffset, limit: 1)
      changes.removedOperations += page.filter { $0.phase == .installed }.map(\.id)
      if page.count < 1 { break }
      operationOffset += page.count
    }
    if item.alias == origin.preferredAlias {
      // Version fallback is a rare catalog operation, scanned in bounded pages.
      var offset = 0
      var fallback: ModelInstallation?
      while true {
        let page = try await persistence.relatedInstallations(
          origin: origin, offset: offset, limit: 1)
        for candidate in page where candidate.id != item.id {
          if let other = candidate.manifest?.origin, other.registryID == origin.registryID,
            other.repository == origin.repository, other.variant == origin.variant,
            candidate.availability == .ready, FileManager.default.fileExists(atPath: candidate.path)
          {
            fallback = candidate
          }
        }
        if page.count < 1 { break }
        offset += page.count
      }
      if var fallback {
        fallback.alias = origin.preferredAlias
        changes.installations = [fallback]
      }
    }
    return changes
  }
  func installationForRemoval(_ id: UUID) async throws -> ModelInstallation {
    guard recoveryState.phase != .recovering else {
      throw MoxError(.busy, "Library recovery is in progress; retry removal when it finishes.")
    }
    return try await installation(id)
  }
  func removeInstallation(_ id: UUID) async throws {
    _ = try await installationForRemoval(id)
    await acquireMutation()
    defer { releaseMutation() }
    var item = try await installation(id)
    if let manifest = item.manifest {
      let root = try artifacts.installedDirectory(for: manifest.origin)
      let path =
        manifest.origin.variant.isEmpty
        ? root.path : root.appendingPathComponent(manifest.origin.variant).path
      guard path == item.path else {
        throw MoxError(.storageFailed, "Managed artifact path does not match its identity.")
      }
      item.deletionPending = true
      try await persistence.commit(.init(installations: [item]))
      try artifacts.prepareRemoval(manifest, id: id)
    }
    try await persistence.commit(removalChanges(item))
    try artifacts.finishRemoval(id: id)
  }
  public func create(provider: ModelProvider, endpoint: URL, manifest: ArtifactManifest)
    async throws -> UUID
  {
    await acquireLifecycle(UUID())
    defer { releaseLifecycle() }
    await acquireMutation()
    defer { releaseMutation() }
    try ArtifactValidation.validate(manifest)
    try artifacts.checkAvailableSpace(for: manifest)
    guard !stopping, runners.isEmpty, failedTerminalSaves.isEmpty else {
      throw MoxError(.busy, "Finish the current download before creating another.")
    }
    guard try await persistence.installation(.origin(manifest.origin)) == nil,
      try await !persistence.hasUnfinishedOperation(origin: manifest.origin)
    else {
      throw MoxError(.busy, "This fixed model revision is already installed or downloading.")
    }
    let operation = DownloadOperation(provider: provider, endpoint: endpoint, manifest: manifest)
    try await persistence.commit(.init(operations: [operation]))
    return operation.id
  }
  public func plan(_ manifest: ArtifactManifest) throws -> ModelDownloadPlan {
    try ArtifactValidation.validate(manifest)
    return try artifacts.spacePlan(for: manifest)
  }
  public func resume(_ id: UUID, source: any ModelFileSource) async throws {
    await acquireLifecycle(id)
    defer { releaseLifecycle() }
    guard !stopping else { throw MoxError(.shuttingDown, "Downloads are stopping.") }
    let operation = try await operation(id)
    guard runners.isEmpty, failedTerminalSaves.isEmpty || failedTerminalSaves[id] != nil,
      [.paused, .failed, .interrupted].contains(operation.phase)
    else { throw MoxError(.busy, "Download cannot be resumed in its current state.") }
    try await transition(id, phase: .downloading)
    // shutdown sets stopping before awaiting the admission owner.
    if stopping {
      try await transition(id, phase: .interrupted)
      throw MoxError(.shuttingDown, "Downloads are stopping.")
    }
    runners[id] = Task { await self.execute(operation, source: source) }
  }
  public func pause(_ id: UUID) async throws {
    await acquireLifecycle(id)
    defer { releaseLifecycle() }
    guard try await operation(id).phase == .downloading else {
      throw MoxError(.busy, "Installation is not in a pausable download phase.")
    }
    if let runner = runners[id] {
      runner.cancel()
      await runner.value
    }
    guard try await operation(id).phase != .installed else {
      throw MoxError(.busy, "Installation finished before pause completed.")
    }
    try await transition(id, phase: .paused)
  }
  public func cancel(_ id: UUID) async throws {
    await acquireLifecycle(id)
    defer { releaseLifecycle() }
    guard try await ![.installed, .committing].contains(operation(id).phase) else {
      throw MoxError(.busy, "A committed installation cannot be cancelled.")
    }
    if let runner = runners[id] {
      runner.cancel()
      await runner.value
    }
    guard try await operation(id).phase != .installed else {
      throw MoxError(.busy, "Installation finished before cancellation completed.")
    }
    try await transition(id, phase: .cancelled)
  }
  public func discard(_ id: UUID) async throws {
    await acquireLifecycle(id)
    defer { releaseLifecycle() }
    await acquireMutation()
    defer { releaseMutation() }
    guard runners[id] == nil, try await operation(id).phase == .cancelled else {
      throw MoxError(.busy, "Cancel the download before discarding its files.")
    }
    let directory = try artifacts.stagingDirectory(for: id)
    try FileManager.default.removeItem(at: directory)
    try await persistence.commit(.init(removedOperations: [id]))
    failedTerminalSaves[id] = nil
  }
  public func shutdown() async {
    stopping = true
    recoveryState.phase = .stopping
    recoveryTask?.cancel()
    let checks = verifications.values.map(\.task)
    checks.forEach { $0.cancel() }
    await recoveryTask?.value
    for check in checks { _ = try? await check.value }
    await acquireLifecycle(UUID())
    defer { releaseLifecycle() }
    let tasks = Array(runners.values)
    tasks.forEach { $0.cancel() }
    for task in tasks { await task.value }
  }
  private func transition(
    _ id: UUID, phase: DownloadPhase, verifiedBytes: Int64? = nil,
    errorCode: String? = nil, failureDomain: String? = nil, failureSystemCode: Int? = nil
  ) async throws {
    await acquireMutation()
    defer { releaseMutation() }
    var item = try await operation(id)
    item.phase = phase
    if let verifiedBytes { item.verifiedBytes = verifiedBytes }
    item.errorCode = errorCode
    item.failureDomain = failureDomain
    item.failureSystemCode = failureSystemCode
    try await persistence.commit(.init(operations: [item]))
    failedTerminalSaves[id] = nil
  }
  private func execute(_ operation: DownloadOperation, source: any ModelFileSource) async {
    let id = operation.id
    defer { runners[id] = nil }
    do {
      if try await completeCommitted(operation.manifest) { return }
      let directory = try artifacts.stagingDirectory(for: id)
      var verified: Int64 = 0
      for file in operation.manifest.files {
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(file.path)
        if FileManager.default.fileExists(atPath: destination.path) {
          do { try ArtifactValidation.verify(file, in: directory) } catch {
            try FileManager.default.removeItem(at: destination)
          }
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
          try await source.download(file, manifest: operation.manifest, to: directory)
        }
        try ArtifactValidation.verify(file, in: directory)
        verified += file.bytes
        try await transition(id, phase: .downloading, verifiedBytes: verified)
      }
      try Task.checkCancellation()
      try await transition(id, phase: .verifying)
      try Task.checkCancellation()
      try await transition(id, phase: .committing)
      _ = try artifacts.commit(operationID: id, manifest: operation.manifest)
      _ = try await completeCommitted(operation.manifest)

    } catch {
      let cancelled = Task.isCancelled
      let system = error as NSError
      do {
        try await transition(
          id, phase: cancelled ? .interrupted : .failed,
          errorCode: cancelled ? nil : (error as? MoxError)?.code.rawValue ?? "sourceFailed",
          failureDomain: error is MoxError
            ? nil
            : ([NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, "OSStatus"].contains(
              system.domain) ? system.domain : "OtherSystemError"),
          failureSystemCode: error is MoxError ? nil : system.code)
      } catch {
        var failed = operation
        failed.phase = .failed
        failed.errorCode = "storageFailed"
        // At most one terminal save can be outstanding: stop further admission
        // until this operation is explicitly retried and durably transitioned.
        failedTerminalSaves[id] = failed
        Logger(subsystem: "dev.mox", category: "download").error(
          "operation=\(id.uuidString, privacy: .public) stage=terminal-save code=storageFailed")
      }
    }
  }
  func recover() async throws {
    await acquireLifecycle(UUID())
    defer { releaseLifecycle() }
    guard runners.isEmpty, !stopping else {
      throw MoxError(.busy, "Recovery requires an idle library.")
    }
    // Only metadata repair holds the mutation gate. Hashing must never hold it.
    await acquireMutation()
    var repairingMetadata = true
    defer { if repairingMetadata { releaseMutation() } }
    var offset = 0
    while true {
      try Task.checkCancellation()
      let page = try await persistence.installations(offset: offset, limit: 1)
      if page.isEmpty { break }
      var removed = 0
      for item in page where item.deletionPending {
        if let manifest = item.manifest { try artifacts.prepareRemoval(manifest, id: item.id) }
        try await persistence.commit(removalChanges(item))
        try artifacts.finishRemoval(id: item.id)
        removed += 1
      }
      offset += page.count - removed
    }
    try artifacts.removeOrphanTrash(keeping: [])
    repairingMetadata = false
    releaseMutation()
    offset = 0
    while true {
      let page = try await persistence.installations(offset: offset, limit: 1)
      if page.isEmpty { break }
      for var item in page {
        if let manifest = item.manifest, FileManager.default.fileExists(atPath: item.path) {
          do {
            try await verifyForRecovery(item.id)
            continue
          } catch is CancellationError { throw CancellationError() } catch {
            if (error as? MoxError)?.code == .storageFailed { throw error }
            logDamaged(manifest.origin)
            continue
          }
        } else {
          item.availability = FileManager.default.fileExists(atPath: item.path) ? .ready : .missing
        }
        await acquireMutation()
        do {
          if var current = try await persistence.installation(.id(item.id)) {
            current.availability = item.availability
            try await persistence.commit(.init(installations: [current]))
          }
        } catch {
          releaseMutation()
          throw error
        }
        releaseMutation()
      }
      recoveryState.inspected += page.count
      offset += page.count
    }
    // Reconcile both missing indexes and incomplete tasks after a file/index commit.
    // A durable installation alone does not prove the operation terminal was saved.
    offset = 0
    while true {
      let page = try await persistence.operations(offset: offset, limit: 1)
      if page.isEmpty { break }
      for var item in page {
        if item.phase.isActive {
          item.phase = .interrupted
          try await persistence.commit(.init(operations: [item]))
        }
        if try await persistence.installation(.origin(item.manifest.origin)) == nil
          || (item.phase != .installed && item.phase != .cancelled)
        {
          let path = try artifacts.installedDirectory(for: item.manifest.origin)
          if FileManager.default.fileExists(atPath: path.path) {
            let manifest: ArtifactManifest
            do {
              manifest = try await verifier.inspect(item.manifest.origin, in: artifacts)
              guard manifest == item.manifest else {
                throw MoxError(.invalidModel, "Committed manifest differs from the operation.")
              }
            } catch is CancellationError { throw CancellationError() } catch {
              logDamaged(item.manifest.origin)
              continue
            }
            try await recoverCommitted(manifest)
          }
        }
      }
      offset += page.count
    }
    // The filesystem cursor retains one entry/manifest instead of a catalog.
    guard
      let entries = FileManager.default.enumerator(
        at: artifacts.root.appendingPathComponent("artifacts"),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsSubdirectoryDescendants])
    else {
      throw MoxError(.storageFailed, "Cannot enumerate installed artifacts.")
    }
    while let child = entries.nextObject() as? URL {
      try Task.checkCancellation()
      let manifest: ArtifactManifest
      do {
        manifest = try artifacts.inspectCommittedDirectory(child, verifyFiles: false)
      } catch is CancellationError { throw CancellationError() } catch { continue }
      if try await persistence.installation(.origin(manifest.origin)) == nil {
        do {
          _ = try await verifier.inspect(manifest.origin, in: artifacts)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logDamaged(manifest.origin)
          continue
        }
        try await recoverCommitted(manifest)
      }
    }
  }
  private func logDamaged(_ origin: ArtifactOrigin) {
    Logger(subsystem: "dev.mox", category: "artifact").error(
      "stage=recovery status=damaged identifier=\(origin.fixedAlias, privacy: .public)")
  }
  /// Both explicit retry and startup recovery finish the same file/index transaction.
  /// A directory alone is insufficient: identity, full manifest and bytes must match.
  private func completeCommitted(_ expected: ArtifactManifest) async throws -> Bool {
    let root = try artifacts.installedDirectory(for: expected.origin)
    guard FileManager.default.fileExists(atPath: root.path) else { return false }
    let actual = try await verifier.inspect(expected.origin, in: artifacts)
    guard actual == expected else {
      throw MoxError(.invalidModel, "Committed artifact does not match the download plan.")
    }
    try await recoverCommitted(actual)
    return true
  }
  private func recoverCommitted(_ manifest: ArtifactManifest) async throws {
    await acquireMutation()
    defer { releaseMutation() }
    var evidenceOffset = 0
    while true {
      let evidence = try await persistence.operations(
        origin: manifest.origin, offset: evidenceOffset, limit: 1)
      if evidence.isEmpty { break }
      guard evidence.allSatisfy({ $0.manifest == manifest }) else {
        throw MoxError(
          .invalidModel, "Committed artifact conflicts with its durable download plan.")
      }
      evidenceOffset += evidence.count
    }
    let root = try artifacts.installedDirectory(for: manifest.origin)
    let path =
      manifest.origin.variant.isEmpty
      ? root.path : root.appendingPathComponent(manifest.origin.variant).path
    var changes: [ModelInstallation] = []
    if var existing = try await persistence.installation(.path(path)) {
      guard existing.manifest == manifest, !existing.deletionPending else {
        throw MoxError(.invalidModel, "Committed artifact conflicts with its installation index.")
      }
      existing.availability = .ready
      changes = [existing]
    } else {
      changes = try await installationChanges(manifest, path: path)
    }
    for index in changes.indices { changes[index].verificationSession = verificationSession }
    try await persistence.commit(.init(installations: changes))
    var offset = 0
    while true {
      var page = try await persistence.operations(origin: manifest.origin, offset: offset, limit: 1)
      if page.isEmpty { break }
      for index in page.indices where page[index].manifest == manifest {
        page[index].phase = .installed
        page[index].verifiedBytes = manifest.files.reduce(0) { $0 + $1.bytes }
        page[index].errorCode = nil
        page[index].failureDomain = nil
        page[index].failureSystemCode = nil
      }
      try await persistence.commit(.init(operations: page))
      offset += page.count
    }
  }
}
