import Foundation
import MoxDomain
import Testing

@testable import MoxCore

private actor IdentityRepository: ModelLibraryPersistence {
  var config = ModelConfiguration.defaults
  var items: [UUID: ModelInstallation] = [:]
  var tasks: [UUID: DownloadOperation] = [:]
  var catalogReads = 0
  var writes: [LibraryChanges] = []
  var failCommit = false
  func seed(_ item: ModelInstallation) { items[item.id] = item }
  func armFailure() { failCommit = true }
  func configuration() -> ModelConfiguration { config }
  func installation(_ lookup: InstallationLookup) -> ModelInstallation? {
    switch lookup {
    case .id(let id): return items[id]
    case .alias(let alias):
      return items.values.first {
        ModelIdentifier.aliasKey($0.alias) == ModelIdentifier.aliasKey(alias)
      }
    case .path(let path): return items.values.first { $0.path == path }
    case .origin(let origin): return items.values.first { $0.manifest?.origin == origin }
    }
  }
  func operation(_ id: UUID) -> DownloadOperation? { tasks[id] }
  func installations(offset: Int, limit: Int) -> [ModelInstallation] {
    catalogReads += 1
    return Array(items.values.dropFirst(offset).prefix(limit))
  }
  func operations(offset: Int, limit: Int) -> [DownloadOperation] {
    catalogReads += 1
    return Array(tasks.values.dropFirst(offset).prefix(limit))
  }
  func installationSummaries(offset: Int, limit: Int) -> [ModelInstallationSummary] {
    installations(offset: offset, limit: limit).map(ModelInstallationSummary.init)
  }
  func operationSummaries(offset: Int, limit: Int) -> [DownloadOperationSummary] {
    operations(offset: offset, limit: limit).map(DownloadOperationSummary.init)
  }
  func operations(origin: ArtifactOrigin, offset: Int, limit: Int) -> [DownloadOperation] {
    Array(tasks.values.filter { $0.manifest.origin == origin }.dropFirst(offset).prefix(limit))
  }
  func hasUnfinishedOperation(origin: ArtifactOrigin) -> Bool {
    tasks.values.contains {
      $0.manifest.origin == origin && $0.phase != .cancelled && $0.phase != .failed
    }
  }
  func relatedInstallations(origin: ArtifactOrigin, offset: Int, limit: Int) -> [ModelInstallation]
  {
    Array(
      items.values.filter { $0.manifest?.origin.preferredAlias == origin.preferredAlias }.dropFirst(
        offset
      ).prefix(limit))
  }
  func installationCount() -> Int { items.count }
  func operationCount() -> Int { tasks.count }
  func activeOperationCount() -> Int { tasks.values.filter { $0.phase.isActive }.count }
  func commit(_ change: LibraryChanges) throws {
    if failCommit {
      failCommit = false
      throw MoxError(.storageFailed, "Injected save failure.")
    }
    writes.append(change)
    if let configuration = change.configuration { config = configuration }
    for item in change.installations { items[item.id] = item }
    for task in change.operations { tasks[task.id] = task }
    for id in change.removedInstallations { items[id] = nil }
    for id in change.removedOperations { tasks[id] = nil }
  }
}
private actor LibraryRuntimeProbe: ModelRuntime {
  func resourceBudgetBytes() -> Int { 512 * 1024 * 1024 }
  func assess(model: LocalModel, maxTokens: Int) -> ResourceAssessment {
    model.resources.assessment(maxTokens: maxTokens, budgetBytes: resourceBudgetBytes())
  }
  var pinned = false
  var rejectUnload = false
  var loadEntered = false
  private var loadWaiter: CheckedContinuation<Void, Never>?
  func setRejectUnload(_ value: Bool) { rejectUnload = value }
  func load(model: LocalModel) async {
    loadEntered = true
    await withCheckedContinuation { loadWaiter = $0 }
  }
  func releaseLoad() {
    loadWaiter?.resume()
    loadWaiter = nil
  }
  func unload(modelID: String) throws {
    if rejectUnload { throw MoxError(.busy, "Model has an active lease.") }
  }
  func setPinned(modelID: String, _ value: Bool) { pinned = value }
  func generate(model: LocalModel, request: GenerationRequest) -> GenerationHandle {
    GenerationHandle(requestID: request.id)
  }
}
private final class LibrarySourceProbe: ModelSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var references = Set<String>()
  var count: Int { lock.withLock { references.count } }
  func saveCredential(_ value: String, registryID: UUID, endpoint: URL) -> String {
    let reference = UUID().uuidString
    lock.withLock { _ = references.insert(reference) }
    return reference
  }
  func deleteCredential(reference: String) { lock.withLock { _ = references.remove(reference) } }
  func make(provider: ModelProvider, endpoint: URL, credentialReference: String?)
    -> any ResolvedModelSource
  { UnusedSource() }
  private struct UnusedSource: ResolvedModelSource {
    func resolve(registryID: UUID, repository: String, selector: String, variant: String)
      async throws -> ArtifactManifest
    { throw MoxError(.connectionLost, "Not used.") }
    func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
      throw MoxError(.connectionLost, "Not used.")
    }
  }
}
@Test func coreCredentialsAndPinRollbackOnStorageFailure() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = IdentityRepository()
  let runtime = LibraryRuntimeProbe()
  let sources = LibrarySourceProbe()
  let manager = DownloadManager(persistence: repository, artifacts: try ArtifactStore(root: root))
  let library = ModelLibraryService(downloads: manager, runtime: runtime, sources: sources)
  let registry = ModelRegistry(
    id: UUID(), name: "fixture", provider: .huggingFace, origin: URL(string: "https://example.org")!
  )
  await repository.armFailure()
  await #expect(throws: MoxError.self) {
    _ = try await library.updateRegistry(
      registry, expectedRevision: 0, credential: "secret", mirrorCredential: nil)
  }
  #expect(sources.count == 0)
  #expect(await repository.config.revision == 0)
  let committed = try await library.updateRegistry(
    registry, expectedRevision: 0, credential: "secret", mirrorCredential: nil)
  #expect(sources.count == 1 && committed.revision == 1)
  let item = ModelInstallation(path: "/tmp/reference", manifest: nil, alias: "fixture")
  await repository.seed(item)
  await repository.armFailure()
  await #expect(throws: MoxError.self) {
    _ = try await library.setPinned(item.id, pinned: true, expectedRevision: 1)
  }
  #expect(await runtime.pinned == false)
  #expect(await repository.items[item.id]?.pinned == false)
  #expect(await repository.catalogReads == 0)
}
@Test func coreDeletionCannotBypassStartingOrActiveRuntimeProtection() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = IdentityRepository()
  let runtime = LibraryRuntimeProbe()
  let item = ModelInstallation(path: model.directory.path, manifest: nil, alias: "fixture")
  await repository.seed(item)
  let manager = DownloadManager(persistence: repository, artifacts: try ArtifactStore(root: root))
  let library = ModelLibraryService(downloads: manager, runtime: runtime)
  let load = Task { try await library.load(item.id) }
  while !(await runtime.loadEntered) { await Task.yield() }
  await #expect(throws: MoxError.self) { try await library.removeInstallation(item.id) }
  #expect(await repository.items[item.id] != nil)
  await runtime.releaseLoad()
  try await load.value
  await runtime.setRejectUnload(true)
  await #expect(throws: MoxError.self) { try await library.removeInstallation(item.id) }
  #expect(await repository.items[item.id] != nil)
  await runtime.setRejectUnload(false)
  try await library.removeInstallation(item.id)
  #expect(await repository.items[item.id] == nil)
  #expect(FileManager.default.fileExists(atPath: model.directory.path))
  #expect(await repository.catalogReads == 0)
}
@Test func singleModelSettingAndResolutionNeverReadCatalog() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = IdentityRepository()
  let item = ModelInstallation(path: "/tmp/fixture", manifest: nil, alias: "fixture")
  await repository.seed(item)
  let manager = DownloadManager(persistence: repository, artifacts: try ArtifactStore(root: root))
  let library = ModelLibraryService(
    downloads: manager, runtime: LibraryRuntimeProbe(), launchSampling: .init(topP: 0.8))
  _ = try await manager.setGlobalSampling(.init(temperature: 0.2), expectedRevision: 0)
  _ = try await manager.setModelSampling(
    item.id, settings: .init(maxTokens: 90), expectedRevision: 1)
  let resolved = try await library.resolveSampling(
    .installed(item.id.uuidString), explicit: .init(temperature: 0.4))
  #expect(resolved.maxTokens == 90 && resolved.maxTokensSource == .model)
  #expect(resolved.temperature == 0.4 && resolved.temperatureSource == .request)
  #expect(resolved.topP == 0.8 && resolved.topPSource == .launch)
  #expect(await repository.catalogReads == 0)
  let writes = await repository.writes
  #expect(
    writes.count == 2 && writes[0].installations.isEmpty && writes[1].installations.count == 1)
  #expect(writes.allSatisfy { $0.operations.isEmpty })
}

@Test func pinnedSettingsRestoreThroughCoreAfterReopen() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = IdentityRepository()
  let runtime = LibraryRuntimeProbe()
  var item = ModelInstallation(path: "/tmp/pinned", manifest: nil, alias: "pinned")
  item.pinned = true
  await repository.seed(item)
  let manager = DownloadManager(persistence: repository, artifacts: try ArtifactStore(root: root))
  let library = ModelLibraryService(downloads: manager, runtime: runtime)
  try await library.restoreRuntimeSettings()
  #expect(await runtime.pinned)
  #expect(await repository.catalogReads == 1)
}

private actor LocalInspectionProbe {
  var entered = false
  var stopped = false
  func inspect(_ path: String) async throws -> LocalModel {
    entered = true
    defer { stopped = true }
    do { try await Task.sleep(for: .seconds(60)) } catch {
      // Simulate a filesystem error delivered after the cancellation signal.
      throw MoxError(.invalidModel, "Read error raced with cancellation.")
    }
    return try LocalModel(path: path)
  }
}
@Test(arguments: [false, true])
func previewInspectionLeavesActorResponsiveAndStopsOnCancellationOrShutdown(shutdown: Bool) async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let probe = LocalInspectionProbe()
  let library = ModelLibraryService(downloads: nil, runtime: LibraryRuntimeProbe(),
    inspectLocalFiles: { try await probe.inspect($0) })
  let preview = Task { try await library.assessResources(.directory(model.directory.path)) }
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !(await probe.entered), ContinuousClock.now < deadline { await Task.yield() }
  #expect(await probe.entered)
  let sampling = try await library.resolveSampling(.directory(model.directory.path))
  #expect(sampling.maxTokens > 0)
  if shutdown { await library.shutdown() } else { preview.cancel() }
  await #expect(throws: CancellationError.self) { try await preview.value }
  #expect(await probe.stopped)
  await library.shutdown()
  await #expect(throws: MoxError.self) {
    _ = try await library.assessResources(.directory(model.directory.path))
  }
}
