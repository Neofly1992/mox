import Foundation
import MoxDomain

/// Owns persistent operations, not their observers. All transitions are saved before
/// publishing their snapshot; only one mutation may cross the persistence await.
public actor DownloadManager {
  private let persistence: any ModelLibraryPersistence
  private let artifacts: ArtifactStore
  private var state: ModelLibrarySnapshot
  private var runners: [UUID: Task<Void, Never>] = [:]
  private var mutationInProgress = false
  public init(persistence: any ModelLibraryPersistence, artifacts: ArtifactStore, state: ModelLibrarySnapshot) {
    self.persistence = persistence; self.artifacts = artifacts; self.state = state
  }
  private static func addInstallation(_ manifest: ArtifactManifest, path: String,
    to snapshot: inout ModelLibrarySnapshot
  ) throws {
    let preferredAlias = manifest.origin.preferredAlias
    if let old = snapshot.installations.firstIndex(where: { $0.alias == preferredAlias }) {
      guard let previous = snapshot.installations[old].manifest,
        previous.origin.registryID == manifest.origin.registryID,
        previous.origin.repository == manifest.origin.repository,
        previous.origin.variant == manifest.origin.variant
      else { throw MoxError(.busy, "A local reference already uses the model alias.") }
      snapshot.installations[old].alias = previous.origin.fixedAlias
    }
    snapshot.installations.append(.init(path: path, manifest: manifest, alias: preferredAlias))
  }
  private static func removeInstallationRecord(_ installation: ModelInstallation,
    from snapshot: inout ModelLibrarySnapshot
  ) {
    snapshot.installations.removeAll { $0.id == installation.id }
    guard let origin = installation.manifest?.origin else { return }
    snapshot.operations.removeAll { $0.manifest.origin == origin && $0.phase == .installed }
    let preferredAlias = origin.preferredAlias
    if installation.alias == preferredAlias,
      let fallback = snapshot.installations.indices.reversed().first(where: {
        let candidate = snapshot.installations[$0].manifest?.origin
        return candidate?.registryID == origin.registryID
          && candidate?.repository == origin.repository
          && candidate?.variant == origin.variant
          && snapshot.installations[$0].availability == .ready
          && FileManager.default.fileExists(atPath: snapshot.installations[$0].path)
      })
    {
      snapshot.installations[fallback].alias = preferredAlias
    }
  }
  public func snapshot() -> ModelLibrarySnapshot { state }

  private func persist(_ next: ModelLibrarySnapshot) async throws {
    guard !mutationInProgress else { throw MoxError(.busy, "Model metadata is being saved; retry the operation.") }
    mutationInProgress = true
    defer { mutationInProgress = false }
    try await persistence.saveLibrary(next)
    state = next
  }
  public func recover() async throws {
    for installation in state.installations where installation.deletionPending {
      if let manifest = installation.manifest {
        try artifacts.prepareRemoval(manifest, id: installation.id)
      }
      var pending = state
      Self.removeInstallationRecord(installation, from: &pending)
      try await persist(pending)
      try artifacts.finishRemoval(id: installation.id)
    }
    try artifacts.removeOrphanTrash(keeping: Set(state.installations.filter(\.deletionPending).map(\.id)))
    var next = state
    for index in next.operations.indices where next.operations[index].phase.isActive {
      next.operations[index].phase = .interrupted
    }
    let inspection = try artifacts.inspectCommitted()
    let ordered = inspection.valid.sorted { lhs, rhs in
      let left = next.operations.firstIndex { $0.manifest.origin == lhs.origin } ?? Int.max
      let right = next.operations.firstIndex { $0.manifest.origin == rhs.origin } ?? Int.max
      return left == right ? lhs.origin.revision < rhs.origin.revision : left < right
    }
    for manifest in ordered {
      let root = try artifacts.installedDirectory(for: manifest.origin)
      let path = manifest.origin.variant.isEmpty ? root.path
        : root.appendingPathComponent(manifest.origin.variant).path
      if !next.installations.contains(where: { $0.path == path }) {
        try Self.addInstallation(manifest, path: path, to: &next)
      }
      for index in next.operations.indices where next.operations[index].manifest == manifest {
        next.operations[index].phase = .installed
      }
    }
    for index in next.installations.indices {
      let path = next.installations[index].path
      if let manifest = next.installations[index].manifest {
        let identifier = try ArtifactValidation.identifier(for: manifest.origin)
        next.installations[index].availability = inspection.damagedIDs.contains(identifier)
          ? .corrupt : (FileManager.default.fileExists(atPath: path) ? .ready : .missing)
      } else {
        next.installations[index].availability = FileManager.default.fileExists(atPath: path)
          ? .ready : .missing
      }
    }
    try await persist(next)
  }
  public func registry(_ id: UUID) throws -> ModelRegistry {
    guard let registry = state.configuration.registries.first(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Model source is not configured.")
    }
    return registry
  }
  public func setDefaultRegistry(_ id: UUID, expectedRevision: UInt64) async throws -> ModelConfiguration {
    guard expectedRevision == state.configuration.revision else {
      throw MoxError(.busy, "Source configuration changed; reload and try again.")
    }
    guard state.configuration.registries.contains(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Default source must be configured first.")
    }
    var next = state
    next.configuration.defaultRegistryID = id
    next.configuration.defaultProvenance = .user
    next.configuration.revision += 1
    try await persist(next)
    return next.configuration
  }
  public func setPublicAPIEnabled(_ enabled: Bool) async throws -> ModelConfiguration {
    var next = state
    next.configuration.publicAPIEnabled = enabled
    next.configuration.revision += 1
    try await persist(next)
    return next.configuration
  }
  public func updateRegistry(_ registry: ModelRegistry, expectedRevision: UInt64) async throws -> ModelConfiguration {
    guard expectedRevision == state.configuration.revision else {
      throw MoxError(.busy, "Source configuration changed; reload and try again.")
    }
    guard registry.name.utf8.count <= 128,
      registry.origin.absoluteString.utf8.count <= 2_048,
      (registry.mirror?.absoluteString.utf8.count ?? 0) <= 2_048
    else { throw MoxError(.invalidParameters, "Model source settings exceed their size limit.") }
    var next = state
    if let index = next.configuration.registries.firstIndex(where: { $0.id == registry.id }) {
      next.configuration.registries[index] = registry
    } else { next.configuration.registries.append(registry) }
    guard next.configuration.registries.count <= 32 else {
      throw MoxError(.resourceLimit, "Model source count exceeds 32.")
    }
    next.configuration.revision += 1
    try await persist(next)
    return next.configuration
  }
  public func importDirectory(path: String, alias: String) async throws -> ModelInstallation {
    let model = try LocalModel(path: path)
    if let existing = state.installations.first(where: { $0.path == model.directory.path }) {
      return existing
    }
    guard !alias.isEmpty, !alias.hasPrefix(ArtifactOrigin.aliasPrefix), alias.utf8.count <= 256,
      !state.installations.contains(where: { $0.alias == alias }) else {
      throw MoxError(.busy, "Model alias is empty or already in use.")
    }
    let installation = ModelInstallation(path: model.directory.path, manifest: nil, alias: alias)
    var next = state
    next.installations.append(installation)
    try await persist(next)
    return installation
  }
  public func installation(_ id: UUID) throws -> ModelInstallation {
    guard let value = state.installations.first(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Model installation was not found.")
    }
    return value
  }
  public func selectInstallation(_ id: UUID) async throws -> ModelLibrarySnapshot {
    let selected = try installation(id)
    guard let manifest = selected.manifest, selected.availability == .ready else {
      throw MoxError(.invalidModel, "Only an available managed model can be selected.")
    }
    _ = try LocalModel(path: selected.path)
    var next = state
    let preferredAlias = manifest.origin.preferredAlias
    if let current = next.installations.firstIndex(where: { $0.alias == preferredAlias && $0.id != id }) {
      guard let previous = next.installations[current].manifest else {
        throw MoxError(.storageFailed, "Model alias points to an external reference.")
      }
      next.installations[current].alias = previous.origin.fixedAlias
    }
    guard let index = next.installations.firstIndex(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Model installation was not found.")
    }
    next.installations[index].alias = preferredAlias
    try await persist(next)
    return next
  }
  public func removeInstallation(_ id: UUID) async throws {
    let item = try installation(id)
    if let manifest = item.manifest {
      let path = try artifacts.installedDirectory(for: manifest.origin)
      let modelPath = manifest.origin.variant.isEmpty ? path.path
        : path.appendingPathComponent(manifest.origin.variant).path
      guard modelPath == item.path else {
        throw MoxError(.storageFailed, "Managed artifact path does not match its identity.")
      }
      var marked = state
      guard let index = marked.installations.firstIndex(where: { $0.id == id }) else {
        throw MoxError(.notFound, "Model installation was not found.")
      }
      marked.installations[index].deletionPending = true
      try await persist(marked)
      try artifacts.prepareRemoval(manifest, id: id)
    }
    var next = state
    Self.removeInstallationRecord(item, from: &next)
    try await persist(next)
    try artifacts.finishRemoval(id: id)
  }
  public func create(provider: ModelProvider, endpoint: URL, manifest: ArtifactManifest) async throws -> UUID {
    try ArtifactValidation.validate(manifest)
    try artifacts.checkAvailableSpace(for: manifest)
    guard !state.installations.contains(where: { $0.manifest?.origin == manifest.origin }),
      !state.operations.contains(where: { $0.manifest.origin == manifest.origin && $0.phase != .cancelled && $0.phase != .failed })
    else { throw MoxError(.busy, "This fixed model revision is already installed or downloading.") }
    let operation = DownloadOperation(provider: provider, endpoint: endpoint, manifest: manifest)
    guard runners.isEmpty else { throw MoxError(.busy, "Finish the current download before creating another.") }
    var next = state
    next.operations.append(operation)
    try await persist(next)
    return operation.id
  }
  public func plan(_ manifest: ArtifactManifest) throws -> ModelDownloadPlan {
    try ArtifactValidation.validate(manifest)
    return try artifacts.spacePlan(for: manifest)
  }
  public func resume(_ id: UUID, source: any ModelFileSource) async throws {
    guard runners.isEmpty, let operation = state.operations.first(where: { $0.id == id }),
      [.paused, .failed, .interrupted].contains(operation.phase) else {
      throw MoxError(.busy, "Download cannot be resumed in its current state.")
    }
    try await transition(id, phase: .downloading)
    runners[id] = Task { await self.execute(id, source: source) }
  }
  public func pause(_ id: UUID) async throws {
    guard let operation = state.operations.first(where: { $0.id == id }),
      operation.phase == .downloading else { throw MoxError(.busy, "Installation is not in a pausable download phase.") }
    if let runner = runners[id] { runner.cancel(); await runner.value }
    guard state.operations.first(where: { $0.id == id })?.phase != .installed else {
      throw MoxError(.busy, "Installation finished before pause completed.")
    }
    try await transition(id, phase: .paused)
  }
  public func cancel(_ id: UUID) async throws {
    guard let operation = state.operations.first(where: { $0.id == id }),
      ![.installed, .committing].contains(operation.phase) else {
      throw MoxError(.busy, "A committed installation cannot be cancelled.")
    }
    if let runner = runners[id] { runner.cancel(); await runner.value }
    guard state.operations.first(where: { $0.id == id })?.phase != .installed else {
      throw MoxError(.busy, "Installation finished before cancellation completed.")
    }
    try await transition(id, phase: .cancelled)
  }
  public func discard(_ id: UUID) async throws {
    guard runners[id] == nil, let operation = state.operations.first(where: { $0.id == id }),
      operation.phase == .cancelled else { throw MoxError(.busy, "Cancel the download before discarding its files.") }
    let directory = try artifacts.stagingDirectory(for: id)
    try FileManager.default.removeItem(at: directory)
    var next = state
    next.operations.removeAll { $0.id == id }
    try await persist(next)
  }
  public func shutdown() async {
    let tasks = Array(runners.values)
    tasks.forEach { $0.cancel() }
    for task in tasks { await task.value }
  }
  private func transition(_ id: UUID, phase: DownloadPhase, verifiedBytes: Int64? = nil, errorCode: String? = nil) async throws {
    var next = state
    guard let index = next.operations.firstIndex(where: { $0.id == id }) else {
      throw MoxError(.notFound, "Download operation was not found.")
    }
    next.operations[index].phase = phase
    if let verifiedBytes { next.operations[index].verifiedBytes = verifiedBytes }
    next.operations[index].errorCode = errorCode
    try await persist(next)
  }
  private func execute(_ id: UUID, source: any ModelFileSource) async {
    defer { runners[id] = nil }
    guard let operation = state.operations.first(where: { $0.id == id }) else { return }
    do {
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
      let destination = try artifacts.commit(operationID: id, manifest: operation.manifest)
      var next = state
      let modelPath = operation.manifest.origin.variant.isEmpty ? destination.path
        : destination.appendingPathComponent(operation.manifest.origin.variant).path
      try Self.addInstallation(operation.manifest, path: modelPath, to: &next)
      if let index = next.operations.firstIndex(where: { $0.id == id }) {
        next.operations[index].phase = .installed
      }
      try await persist(next)
    } catch {
      let cancelled = Task.isCancelled
      try? await transition(id, phase: cancelled ? .interrupted : .failed,
        errorCode: cancelled ? nil : (error as? MoxError)?.code.rawValue ?? "sourceFailed")
    }
  }
}
