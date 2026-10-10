import Foundation
import MoxDomain
import OSLog

/// The runtime port covers the resource operations required by library use cases.
public protocol ModelRuntime: Sendable {
  func resourceBudgetBytes() async -> Int
  func assess(model: LocalModel, maxTokens: Int) async -> ResourceAssessment
  func load(model: LocalModel) async throws
  func unload(modelID: String) async throws
  func setPinned(modelID: String, _ pinned: Bool) async
  func generate(model: LocalModel, request: GenerationRequest) async throws -> GenerationHandle
}
extension RuntimeCoordinator: ModelRuntime {}

public struct StartedGeneration: Sendable {
  public let handle: GenerationHandle
  public let modelID: String
}

public struct LibraryDiagnostic: Sendable {
  public let stage: String
  public let code: String
}
public struct ModelPullRequest: Sendable {
  public let registryID: UUID
  public let provider: ModelProvider
  public let endpoint: URL
  public let repository: String
  public let selector: String
  public let variant: String
  public init(
    registryID: UUID, provider: ModelProvider, endpoint: URL,
    repository: String, selector: String, variant: String
  ) {
    self.registryID = registryID
    self.provider = provider
    self.endpoint = endpoint
    self.repository = repository
    self.selector = selector
    self.variant = variant
  }
}
public enum ModelReference: Sendable {
  case installed(String)
  case directory(String)
}

/// Shared library use cases. Owns admission between lookup, runtime awaits and
/// metadata changes; transport callers cannot bypass removal or pin protection.
public actor ModelLibraryService {
  private let downloads: DownloadManager?
  private let runtime: any ModelRuntime
  private let sources: (any ModelSourceFactory)?
  private let launchSampling: SamplingSettings
  private var diagnostics: [LibraryDiagnostic] = []
  public func diagnosticEvents() -> [LibraryDiagnostic] { diagnostics }
  private func record(stage: String, code: String) {
    diagnostics.append(.init(stage: stage, code: code))
    if diagnostics.count > 256 { diagnostics.removeFirst(diagnostics.count - 256) }
  }
  private var starting: [String: Int] = [:]
  private var removing = Set<String>()
  private var closing = false
  private var localInspections: [UUID: Task<LocalModel, Error>] = [:]
  private static let maximumLocalInspections = 4
  private let inspectLocalFiles: @Sendable (String) async throws -> LocalModel
  public init(
    downloads: DownloadManager?, runtime: any ModelRuntime,
    sources: (any ModelSourceFactory)? = nil, launchSampling: SamplingSettings = .init(),
    inspectLocalFiles: @escaping @Sendable (String) async throws -> LocalModel = {
      try LocalModel(path: $0)
    }
  ) {
    self.downloads = downloads
    self.runtime = runtime
    self.sources = sources
    self.launchSampling = launchSampling
    self.inspectLocalFiles = inspectLocalFiles
  }
  /// Cancel and join owned file checks before shutting down their dependencies.
  public func shutdown() async {
    closing = true
    let tasks = Array(localInspections.values)
    tasks.forEach { $0.cancel() }
    for task in tasks { _ = try? await task.value }
  }
  private func inspectLocalModel(_ path: String) async throws -> LocalModel {
    guard !closing else { throw MoxError(.shuttingDown, "Model library is stopping.") }
    try Task.checkCancellation()
    guard localInspections.count < Self.maximumLocalInspections else {
      throw MoxError(.busy, "Local model inspection capacity reached; retry shortly.")
    }
    let id = UUID()
    let inspect = inspectLocalFiles
    let task = Task.detached {
      try Task.checkCancellation()
      do {
        let model = try await inspect(path)
        try Task.checkCancellation()
        return model
      } catch {
        // A file error racing with cancellation must not become an unknown preview.
        try Task.checkCancellation()
        throw error
      }
    }
    localInspections[id] = task
    defer { localInspections[id] = nil }
    return try await withTaskCancellationHandler {
      let model = try await task.value
      try Task.checkCancellation()
      return model
    } onCancel: { task.cancel() }
  }
  private func library() throws -> DownloadManager {
    guard let downloads else { throw MoxError(.shuttingDown, "Model library is unavailable.") }
    return downloads
  }
  private func sourceFactory() throws -> any ModelSourceFactory {
    guard let sources else { throw MoxError(.shuttingDown, "Model sources are unavailable.") }
    return sources
  }
  public func restoreRuntimeSettings() async throws {
    let downloads = try library()
    var offset = 0
    while true {
      let page = try await downloads.installationSummaries(offset: offset)
      for item in page where item.pinned && !item.deletionPending {
        await runtime.setPinned(
          modelID: LocalModelIdentity.identifier(for: URL(fileURLWithPath: item.path)), true)
      }
      if page.count < 100 { break }
      offset += page.count
    }
  }
  public func updateRegistry(
    _ input: ModelRegistry, expectedRevision: UInt64,
    credential: String?, mirrorCredential: String?
  ) async throws -> ModelConfiguration {
    let downloads = try library()
    let sources = try sourceFactory()
    let configuration = try await downloads.configuration()
    guard expectedRevision == configuration.revision else {
      throw MoxError(.busy, "Source configuration changed; reload and try again.")
    }
    var registry = input
    // Validate both endpoints even when no credential is provided.
    _ = try sources.make(
      provider: registry.provider, endpoint: registry.origin, credentialReference: nil)
    if let mirror = registry.mirror {
      _ = try sources.make(provider: registry.provider, endpoint: mirror, credentialReference: nil)
    }
    let previous = configuration.registries.first { $0.id == registry.id }
    if let previous {
      guard previous.origin == registry.origin, previous.provider == registry.provider else {
        throw MoxError(.busy, "Create a new source for a different origin or protocol.")
      }
      registry.credentialReference = previous.credentialReference
      registry.mirrorCredentialReference =
        previous.mirror == registry.mirror
        ? previous.mirrorCredentialReference : nil
    } else {
      registry.credentialReference = nil
      registry.mirrorCredentialReference = nil
    }
    var stagedCredentials: [String] = []
    let updated: ModelConfiguration
    do {
      if let credential = credential {
        let reference = try sources.saveCredential(
          credential, registryID: registry.id, endpoint: registry.origin)
        stagedCredentials.append(reference)
        registry.credentialReference = reference
      }
      if let credential = mirrorCredential, let mirror = registry.mirror {
        let reference = try sources.saveCredential(
          credential, registryID: registry.id, endpoint: mirror)
        stagedCredentials.append(reference)
        registry.mirrorCredentialReference = reference
      }
      updated = try await downloads.updateRegistry(
        registry, expectedRevision: expectedRevision)
    } catch {
      var cleanupFailed = false
      for reference in stagedCredentials {
        do { try sources.deleteCredential(reference: reference) } catch { cleanupFailed = true }
      }
      if cleanupFailed {
        throw MoxError(
          .storageFailed, "Unused source credentials could not be removed from Keychain.")
      }
      throw error
    }
    if let previous {
      let activeReferences = Set(
        updated.registries.flatMap {
          [$0.credentialReference, $0.mirrorCredentialReference].compactMap { $0 }
        })
      for reference in [previous.credentialReference, previous.mirrorCredentialReference]
        .compactMap({ $0 })
      where !activeReferences.contains(reference) {
        do { try sources.deleteCredential(reference: reference) } catch {
          record(stage: "source.credential-retirement", code: "storageFailed")
          Logger(subsystem: "dev.mox", category: "source").error("stage=keychain cleanup=failed")
        }
      }
    }
    return updated
  }
  private func resolvePull(
    registryID: UUID, provider: ModelProvider, endpoint: URL,
    repository: String, selector: String, variant: String
  )
    async throws -> (any ResolvedModelSource, ArtifactManifest, URL)
  {
    let registry = try await library().registry(registryID)
    guard registry.provider == provider else {
      throw MoxError(.invalidParameters, "Source protocol does not match its configuration.")
    }
    let selectedEndpoint = registry.mirror ?? registry.origin
    guard endpoint == selectedEndpoint else {
      throw MoxError(.invalidParameters, "Selected source endpoint changed; refresh its settings.")
    }
    let source = try sourceFactory().make(
      provider: provider, endpoint: endpoint,
      credentialReference: registry.credentialReference(for: endpoint))
    let manifest = try await source.resolve(
      registryID: registryID,
      repository: repository, selector: selector, variant: variant)
    return (source, manifest, endpoint)
  }
  private func resolvePull(_ reference: ModelPullRequest) async throws -> (
    any ResolvedModelSource, ArtifactManifest, URL
  ) {
    try await resolvePull(
      registryID: reference.registryID, provider: reference.provider,
      endpoint: reference.endpoint, repository: reference.repository, selector: reference.selector,
      variant: reference.variant)
  }
  public func planDownload(_ reference: ModelPullRequest) async throws -> ModelDownloadPlan {
    let (source, manifest, _) = try await resolvePull(reference)
    let disk = try await library().plan(manifest)
    let budget = await runtime.resourceBudgetBytes()
    let resources: ResourceAssessment
    do {
      guard let config = try await source.resourceConfiguration(manifest) else {
        throw MoxError(.invalidModel, "Small model configuration unavailable.")
      }
      let bytes = manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) {
        $0 + $1.bytes
      }
      let model = try ModelResources(configuration: config, weightBytes: Int(bytes))
      resources = model.assessment(maxTokens: Sampling.defaultMaxTokens, budgetBytes: budget)
    } catch is CancellationError { throw CancellationError() } catch {
      resources = .unknown(
        budgetBytes: budget,
        reason:
          "Model metadata is unavailable or unsupported; no weights were fetched for estimation.")
    }
    try Task.checkCancellation()
    return .init(
      manifest: manifest, totalBytes: disk.totalBytes, peakBytes: disk.peakBytes,
      availableBytes: disk.availableBytes, resources: resources)
  }
  /// Doctor owns this cancellable read-only inspection, separate from recovery state.
  public func inspectModelReadOnly(_ reference: ModelReference) async throws {
    let (path, item) = try await resolve(reference)
    try beginUsing(path)
    defer { endUsing(path) }
    if let item, item.manifest != nil {
      try await library().inspectInstallationReadOnly(item)
      return
    }
    _ = try await inspectLocalModel(path)
  }
  public func assessResources(_ reference: ModelReference, explicit: SamplingSettings = .init())
    async throws -> ResourceAssessment
  {
    let (path, _) = try await resolve(reference)
    try beginUsing(path)
    defer { endUsing(path) }
    let effective = try await resolveSampling(reference, explicit: explicit)
    do {
      let model = try await inspectLocalModel(path)
      return await runtime.assess(model: model, maxTokens: effective.maxTokens)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MoxError where error.code == .busy || error.code == .shuttingDown {
      throw error
    } catch {
      try Task.checkCancellation()
      return .unknown(
        budgetBytes: await runtime.resourceBudgetBytes(),
        reason:
          "Model assets or architecture cannot be reliably assessed. Runtime validation will reject unsupported assets."
      )
    }
  }

  public func startDownload(_ reference: ModelPullRequest) async throws -> UUID {
    let (source, manifest, endpoint) = try await resolvePull(reference)
    let downloads = try library()
    let id = try await downloads.create(
      provider: reference.provider, endpoint: endpoint, manifest: manifest)
    try await downloads.resume(id, source: source)
    return id
  }
  public func resumeDownload(_ id: UUID) async throws {
    let downloads = try library()
    let operation = try await downloads.operation(id)
    let registry = try await downloads.registry(operation.manifest.origin.registryID)
    let source = try sourceFactory().make(
      provider: operation.provider, endpoint: operation.endpoint,
      credentialReference: registry.credentialReference(for: operation.endpoint))
    try await downloads.resume(id, source: source)
  }
  private func resolve(_ reference: ModelReference, verifyContents: Bool = false) async throws -> (
    String, ModelInstallation?
  ) {
    var item: ModelInstallation?
    let path: String
    switch reference {
    case .installed(let identifier):
      item = try await downloads?.findInstalled(identifier: identifier)
      guard let item else { throw MoxError(.notFound, "Installed model was not found.") }
      path = item.path
    case .directory(let directory):
      path = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
      item = try await downloads?.findInstallation(.path(path))
      if item == nil { try await downloads?.validateExternalReference(path: path) }
    }
    if verifyContents, let installed = item, installed.manifest != nil, let downloads {
      item = try await downloads.verifyInstallation(installed.id)
    }
    if let item,
      (item.availability != .ready && item.availability != .checking) || item.deletionPending
    {
      throw MoxError(
        .invalidModel, "Managed model is unavailable; inspect or remove the installation.")
    }
    guard !removing.contains(path) else { throw MoxError(.busy, "Model removal is in progress.") }
    return (path, item)
  }
  public func resolveSampling(
    _ reference: ModelReference,
    explicit: SamplingSettings = .init()
  ) async throws -> EffectiveSampling {
    let (_, item) = try await resolve(reference)
    return try EffectiveSampling.resolve(
      request: explicit, model: item?.samplingSettings ?? .init(),
      launch: launchSampling, global: try await downloads?.configuration().globalSampling ?? .init()
    )
  }
  private func beginUsing(_ path: String) throws {
    guard !removing.contains(path) else { throw MoxError(.busy, "Model removal is in progress.") }
    starting[path, default: 0] += 1
  }
  private func endUsing(_ path: String) {
    if starting[path] == 1 { starting[path] = nil } else { starting[path, default: 1] -= 1 }
  }
  private struct GenerationPlan: Sendable {
    let model: LocalModel
    let installation: ModelInstallation?
    let request: GenerationRequest
  }
  private func planGeneration(
    _ reference: ModelReference, request: GenerationRequest,
    explicitSampling: SamplingSettings, requireVerifiedTools: Bool
  ) async throws -> GenerationPlan {
    let (path, item) = try await resolve(reference)
    try Task.checkCancellation()
    let model = try await inspectLocalModel(path)
    if requireVerifiedTools, request.toolChoice == .auto {
      guard let item, VerifiedToolModel.supports(item), model.modelType == "qwen3" else {
        throw MoxError(.unsupportedInput, "This model has no verified tool-call capability.")
      }
    }
    let effective = try EffectiveSampling.resolve(
      request: explicitSampling,
      model: item?.samplingSettings ?? .init(), launch: launchSampling,
      global: try await downloads?.configuration().globalSampling ?? .init())
    return .init(
      model: model, installation: item, request: try request.replacingSampling(effective.sampling()))
  }
  private func executePlan(_ plan: GenerationPlan) async throws -> StartedGeneration {
    try Task.checkCancellation()
    let path = plan.model.directory.path
    try beginUsing(path)
    defer { endUsing(path) }
    if let item = plan.installation, item.manifest != nil, let downloads {
      _ = try await downloads.verifyInstallation(item.id)
    }
    try Task.checkCancellation()
    if plan.installation?.pinned == true { await runtime.setPinned(modelID: plan.model.id, true) }
    try Task.checkCancellation()
    let handle = try await runtime.generate(model: plan.model, request: plan.request)
    return StartedGeneration(handle: handle, modelID: plan.model.id)
  }
  public func generate(
    _ reference: ModelReference, request: GenerationRequest,
    explicitSampling: SamplingSettings, requireVerifiedTools: Bool = false
  ) async throws -> StartedGeneration {
    let plan = try await planGeneration(
      reference, request: request,
      explicitSampling: explicitSampling, requireVerifiedTools: requireVerifiedTools)
    return try await executePlan(plan)
  }
  /// The supplied handle owns preparation and execution from admission through
  /// actual backend stop. Only metadata validation precedes HTTP success headers.
  public func startGeneration(
    _ reference: ModelReference, request: GenerationRequest,
    explicitSampling: SamplingSettings, requireVerifiedTools: Bool = false,
    output: GenerationHandle
  ) async throws -> String {
    let preparation = Task {
      try await self.planGeneration(
        reference, request: request,
        explicitSampling: explicitSampling, requireVerifiedTools: requireVerifiedTools)
    }
    let work = Task {
      await withTaskCancellationHandler {
        do {
          let plan = try await preparation.value
          try Task.checkCancellation()
          output.emit(.phase("checking"))
          let started = try await self.executePlan(plan)
          let inner = started.handle
          await withTaskCancellationHandler {
            for await event in inner.events {
              if event.payload.isTerminal {
                await inner.waitUntilStopped()
                output.finish(event.payload)
              } else if !output.emit(event.payload) {
                inner.cancel()
              }
            }
            await inner.waitUntilStopped()
          } onCancel: {
            inner.cancel()
          }
        } catch is CancellationError {
          output.finish(.finished(.cancelled))
        } catch {
          output.finish(
            .failed(
              (error as? MoxError)
                ?? MoxError(
                  .generationFailed, "Generation preparation failed; inspect diagnostics.")))
        }
      } onCancel: {
        preparation.cancel()
      }
    }
    output.own(work)
    do { return try await preparation.value.model.id } catch {
      await work.value
      throw error
    }
  }
  public func load(_ id: UUID) async throws {
    let item = try await library().installation(id)
    let (path, _) = try await resolve(.directory(item.path), verifyContents: true)
    try beginUsing(path)
    defer { endUsing(path) }
    let model = try await inspectLocalModel(path)
    if item.pinned { await runtime.setPinned(modelID: model.id, true) }
    try await runtime.load(model: model)
  }
  private func admitRemoval(_ path: String) throws {
    guard starting[path] == nil, !removing.contains(path) else {
      throw MoxError(.busy, "Model has a request starting or removal in progress.")
    }
    removing.insert(path)
  }
  public func unload(_ id: UUID) async throws {
    let item = try await library().installation(id)
    try admitRemoval(item.path)
    defer { removing.remove(item.path) }
    try await runtime.unload(
      modelID: LocalModelIdentity.identifier(for: URL(fileURLWithPath: item.path)))
  }
  public func removeInstallation(_ id: UUID) async throws {
    let downloads = try library()
    let item = try await downloads.installationForRemoval(id)
    try admitRemoval(item.path)
    defer { removing.remove(item.path) }
    let modelID = LocalModelIdentity.identifier(for: URL(fileURLWithPath: item.path))
    try await runtime.unload(modelID: modelID)
    try await downloads.removeInstallation(id)
    await runtime.setPinned(
      modelID: modelID,
      try await downloads.findInstallation(.path(item.path))?.pinned ?? false)
  }
  public func setPinned(_ id: UUID, pinned: Bool, expectedRevision: UInt64) async throws
    -> ModelInstallation
  {
    let downloads = try library()
    let item = try await downloads.installation(id)
    try beginUsing(item.path)
    defer { endUsing(item.path) }
    let modelID = LocalModelIdentity.identifier(for: URL(fileURLWithPath: item.path))
    if pinned { await runtime.setPinned(modelID: modelID, true) }
    do {
      let updated = try await downloads.setPinned(
        id, pinned: pinned, expectedRevision: expectedRevision)
      await runtime.setPinned(
        modelID: modelID,
        try await downloads.findInstallation(.path(item.path))?.pinned ?? false)
      return updated
    } catch {
      await runtime.setPinned(
        modelID: modelID,
        try await downloads.findInstallation(.path(item.path))?.pinned ?? false)
      throw error
    }
  }
}
