import CryptoKit
import Foundation
import MoxDomain
import Testing
@testable import MoxCore

private actor MemoryLibrary: SnapshotTestPersistence {
  var value = ModelLibrarySnapshot()
  func readLibrary() -> ModelLibrarySnapshot { value }
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) { value = snapshot }
}
private actor SaveGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
private actor BlockedLibrary: SnapshotTestPersistence {
  var value = ModelLibrarySnapshot()
  var blockNext = false
  let gate: SaveGate
  init(gate: SaveGate) { self.gate = gate }
  func readLibrary() -> ModelLibrarySnapshot { value }
  func arm() { blockNext = true }
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) async {
    if blockNext { blockNext = false; await gate.wait() }
    value = snapshot
  }
}
private actor TransferGate {
  var entered = false
  var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
private struct GatedSource: ModelFileSource {
  let directory: URL
  let gate: TransferGate
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    await gate.wait()
    try FileManager.default.copyItem(at: directory.appendingPathComponent(file.path),
      to: root.appendingPathComponent(file.path))
  }
}
private struct FailingDomainSource: ModelFileSource {
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
      userInfo: [NSLocalizedDescriptionKey: "private-url-token-must-not-be-exported"])
  }
}
@Test func downloadFailureStoresOnlySafeSystemClassification() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/failure",
    revision: String(repeating: "f", count: 40)), files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "a", count: 64)))])
  let db = MemoryLibrary()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let id = try await manager.create(provider: .huggingFace,
    endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  try await manager.resume(id, source: FailingDomainSource())
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.snapshot().operations.first?.phase != .failed,
    ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  let operation = try #require((try await manager.snapshot()).operations.first)
  #expect(operation.errorCode == "sourceFailed")
  #expect(operation.failureDomain == NSURLErrorDomain)
  #expect(operation.failureSystemCode == NSURLErrorTimedOut)
  #expect(!String(decoding: try JSONEncoder().encode(operation), as: UTF8.self)
    .contains("private-url-token-must-not-be-exported"))
  await manager.shutdown()
}
@Test func configurationSaveCannotStrandDownloadProgress() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try FileManager.default.contentsOfDirectory(at: model.directory,
    includingPropertiesForKeys: nil).map { url in
    let data = try Data(contentsOf: url)
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/race",
    revision: String(repeating: "c", count: 40)), files: files)
  let saveGate = SaveGate()
  let transferGate = TransferGate()
  let db = BlockedLibrary(gate: saveGate)
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let id = try await manager.create(provider: .huggingFace,
    endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  try await manager.resume(id, source: GatedSource(directory: model.directory, gate: transferGate))
  while !(await transferGate.entered) { await Task.yield() }
  await db.arm()
  let configuration = Task { try await manager.setPublicAPIEnabled(true) }
  while !(await saveGate.entered) { await Task.yield() }
  await transferGate.release()
  try await Task.sleep(for: .milliseconds(100))
  await saveGate.release()
  _ = try await configuration.value
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.snapshot().operations.first?.phase != .installed,
    ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  let saved = await db.readLibrary()
  #expect(saved.configuration.publicAPIEnabled)
  #expect(saved.operations.first?.phase == .installed)
  #expect(saved.installations.count == 1)
  await manager.shutdown()
}
private struct FixtureSource: ModelFileSource {
  let directory: URL
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    try Task.checkCancellation()
    try FileManager.default.copyItem(at: directory.appendingPathComponent(file.path),
      to: root.appendingPathComponent(file.path))
  }
}
private actor InterruptingSource: ModelFileSource {
  let directory: URL
  var calls: [String: Int] = [:]
  var failOnCall = 2
  init(directory: URL) { self.directory = directory }
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    calls[file.path, default: 0] += 1
    if calls.values.reduce(0, +) == failOnCall {
      failOnCall = -1
      throw MoxError(.connectionLost, "Simulated connection loss.")
    }
    try FileManager.default.copyItem(at: directory.appendingPathComponent(file.path),
      to: root.appendingPathComponent(file.path))
  }
  func count(_ path: String) -> Int { calls[path, default: 0] }
}

@Test func downloadPersistsFixedFilesAndRepairsAfterReopen() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let origin = ArtifactOrigin(registryID: UUID(), repository: "fixture/model",
    revision: String(repeating: "a", count: 40))
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil).map { url in
    let data = try Data(contentsOf: url)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count), digest: .sha256(hash))
  }
  let manifest = ArtifactManifest(origin: origin, files: files)
  let db = MemoryLibrary()
  let store = try ArtifactStore(root: root)
  let manager = DownloadManager(persistence: db, artifacts: store)
  let id = try await manager.create(provider: .modelScope, endpoint: URL(string: "https://modelscope.cn")!, manifest: manifest)
  try await manager.resume(id, source: FixtureSource(directory: model.directory))
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.snapshot().operations.first?.phase != .installed, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await manager.snapshot().installations.count == 1)
  let recovered = DownloadManager(persistence: db, artifacts: store)
  try await recovered.recover()
  #expect(try await recovered.snapshot().installations.count == 1)
  _ = try LocalModel(path: (try await recovered.snapshot().installations[0].path))
}

@Test func failedTransferReopensAndReusesVerifiedFiles() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil)
    .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
      let data = try Data(contentsOf: url)
      return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
        digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
  #expect(files.count >= 2)
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/model",
    revision: String(repeating: "b", count: 40)), files: files)
  let db = MemoryLibrary()
  let artifacts = try ArtifactStore(root: root)
  let manager = DownloadManager(persistence: db, artifacts: artifacts)
  let source = InterruptingSource(directory: model.directory)
  let id = try await manager.create(provider: .modelScope,
    endpoint: URL(string: "https://modelscope.cn")!, manifest: manifest)
  try await manager.resume(id, source: source)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.snapshot().operations.first?.phase != .failed, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await manager.snapshot().operations.first?.phase == .failed)
  let recovered = DownloadManager(persistence: db, artifacts: artifacts)
  try await recovered.recover()
  try await recovered.resume(id, source: source)
  while try await recovered.snapshot().operations.first?.phase != .installed, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await recovered.snapshot().operations.first?.phase == .installed)
  #expect(await source.count(files[0].path) == 1)
  #expect(await source.count(files[1].path) == 2)
}

@Test func registryRevisionConflictAndSourceIdentityAreStable() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let db = MemoryLibrary()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let configured = ModelRegistry(id: UUID(), name: "Custom HF", provider: .huggingFace,
    origin: URL(string: "https://hub.example")!)
  let updated = try await manager.updateRegistry(configured, expectedRevision: 0)
  #expect(updated.revision == 1)
  await #expect(throws: MoxError.self) {
    _ = try await manager.updateRegistry(configured, expectedRevision: 0)
  }
  let persisted = await db.readLibrary()
  #expect(persisted.configuration.revision == 1)
  #expect(persisted.configuration.registries.contains { $0.id == configured.id && $0.origin == configured.origin })
  let chosen = try await manager.setDefaultRegistry(configured.id, expectedRevision: 1)
  #expect(chosen.defaultRegistryID == configured.id)
  #expect(chosen.defaultProvenance == .user)
}

@Test func defaultSourceSelectionUsesConfiguredRegistry() {
  var configuration = ModelConfiguration.defaults
  let custom = ModelRegistry(id: UUID(), name: "Custom HF", provider: .huggingFace,
    origin: URL(string: "https://mirror.example")!)
  configuration.registries.append(custom)
  configuration.defaultRegistryID = custom.id
  #expect(configuration.preferredRegistry()?.id == custom.id)
  #expect(configuration.preferredRegistry(for: .huggingFace)?.id == custom.id)
  #expect(configuration.preferredRegistry(for: .modelScope)?.provider == .modelScope)
}

@Test func credentialReferenceNeverFollowsRemovedMirror() throws {
  let origin = URL(string: "https://source.example")!
  let mirror = URL(string: "https://mirror.example")!
  var registry = ModelRegistry(id: UUID(), name: "Source", provider: .huggingFace,
    origin: origin, mirror: mirror, credentialReference: "origin-secret",
    mirrorCredentialReference: "mirror-secret")
  #expect(try registry.credentialReference(for: origin) == "origin-secret")
  #expect(try registry.credentialReference(for: mirror) == "mirror-secret")
  registry.mirror = URL(string: "https://new-mirror.example")!
  registry.mirrorCredentialReference = nil
  #expect(throws: MoxError.self) { try registry.credentialReference(for: mirror) }
  #expect(try registry.credentialReference(for: registry.mirror!) == nil)
}

@Test func importedReferenceRemovalNeverDeletesUserDirectory() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let db = MemoryLibrary()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let imported = try await manager.importDirectory(path: model.directory.path, alias: "my-model")
  let repeated = try await manager.importDirectory(path: model.directory.path, alias: "my-model")
  #expect(repeated.id == imported.id)
  try await manager.removeInstallation(imported.id)
  #expect(FileManager.default.fileExists(atPath: model.directory.path))
  #expect(try await manager.snapshot().installations.isEmpty)
}

@Test(arguments: [0, 1, 2])
func managedDeletionRecoveryCompletesAtEveryBoundary(boundary: Int) async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let artifacts = try ArtifactStore(root: root)
  let operation = UUID()
  let staging = try artifacts.stagingDirectory(for: operation)
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil)
  let manifestFiles = try files.map { url in
    let data = try Data(contentsOf: url)
    try data.write(to: staging.appendingPathComponent(url.lastPathComponent))
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/model",
    revision: String(repeating: "a", count: 40)), files: manifestFiles)
  let installed = try artifacts.commit(operationID: operation, manifest: manifest)
  var installation = ModelInstallation(path: installed.path, manifest: manifest, alias: "fixture")
  installation.deletionPending = true
  let db = MemoryLibrary()
  if boundary < 2 {
    var download = DownloadOperation(provider: .huggingFace,
      endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
    download.phase = .installed
    await db.saveLibrary(.init(installations: [installation], operations: [download]))
  }
  if boundary > 0 { try artifacts.prepareRemoval(manifest, id: installation.id) }
  let manager = DownloadManager(persistence: db, artifacts: artifacts)
  try await manager.recover()
  #expect(try await manager.snapshot().installations.isEmpty)
  #expect(try await manager.snapshot().operations.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: installed.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("trash").path).isEmpty)
}

@Test(arguments: ["missing", "digest", "manifest"])
func damagedInstallationDoesNotBlockHealthyRecovery(kind: String) async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let artifacts = try ArtifactStore(root: root)
  let sourceFiles = try FileManager.default.contentsOfDirectory(at: model.directory,
    includingPropertiesForKeys: nil)
  let files = try sourceFiles.map { url in
    let data = try Data(contentsOf: url)
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let registryID = UUID()
  var installed: [ModelInstallation] = []
  for letter in ["a", "b"] {
    let operation = UUID()
    let staging = try artifacts.stagingDirectory(for: operation)
    for file in sourceFiles {
      try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
    }
    let manifest = ArtifactManifest(origin: .init(registryID: registryID,
      repository: "fixture/model", revision: String(repeating: letter, count: 40)), files: files)
    let committed = try artifacts.commit(operationID: operation, manifest: manifest)
    installed.append(ModelInstallation(path: committed.path, manifest: manifest,
      alias: manifest.origin.fixedAlias))
  }
  let damaged = URL(fileURLWithPath: installed[1].path)
  switch kind {
  case "missing": try FileManager.default.removeItem(at: damaged.appendingPathComponent("tokenizer_config.json"))
  case "digest": try Data("wrong".utf8).write(to: damaged.appendingPathComponent("tokenizer_config.json"))
  default: try Data("not-json".utf8).write(to: damaged.appendingPathComponent("mox-manifest.json"))
  }
  let db = MemoryLibrary()
  await db.saveLibrary(.init(installations: installed))
  let manager = DownloadManager(persistence: db, artifacts: artifacts)
  try await manager.recover()
  let recovered = try await manager.snapshot().installations
  #expect(recovered.first?.availability == .ready)
  #expect(recovered.last?.availability == .corrupt)
  try await manager.removeInstallation(installed[1].id)
  #expect(try await manager.snapshot().installations.count == 1)
  #expect(FileManager.default.fileExists(atPath: installed[0].path))
}

@Test func missingManagedFilesCanBeRemovedAndRecovered() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let artifacts = try ArtifactStore(root: root)
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil)
    .map { url in
      let data = try Data(contentsOf: url)
      return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
        digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/model",
    revision: String(repeating: "c", count: 40)), files: files)
  let missing = try artifacts.installedDirectory(for: manifest.origin)
  let installed = ModelInstallation(path: missing.path, manifest: manifest,
    alias: manifest.origin.preferredAlias)
  let db = MemoryLibrary()
  await db.saveLibrary(.init(installations: [installed]))
  let manager = DownloadManager(persistence: db, artifacts: artifacts)
  try await manager.removeInstallation(installed.id)
  #expect(try await manager.snapshot().installations.isEmpty)

  var pending = installed
  pending.deletionPending = true
  await db.saveLibrary(.init(installations: [pending]))
  let restarted = DownloadManager(persistence: db, artifacts: artifacts)
  try await restarted.recover()
  #expect(try await restarted.snapshot().installations.isEmpty)
}

@Test func newRevisionSwitchesPreferredAliasAndOldVersionRemainsSelectable() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil)
    .map { url in
      let data = try Data(contentsOf: url)
      return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
        digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
  let registryID = UUID()
  let manifests = ["a", "b"].map { letter in
    ArtifactManifest(origin: .init(registryID: registryID, repository: "fixture/model",
      revision: String(repeating: letter, count: 40)), files: files)
  }
  let db = MemoryLibrary()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  for manifest in manifests {
    let id = try await manager.create(provider: .huggingFace,
      endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
    try await manager.resume(id, source: FixtureSource(directory: model.directory))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await manager.snapshot().operations.first(where: { $0.id == id })?.phase != .installed,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await manager.snapshot().operations.first(where: { $0.id == id })?.phase == .installed)
  }
  let installed = try await manager.snapshot().installations
  #expect(installed.count == 2)
  #expect(installed[0].alias == manifests[0].origin.fixedAlias)
  #expect(installed[1].alias == manifests[1].origin.preferredAlias)
  try await manager.selectInstallation(installed[0].id)
  let selected = try await manager.snapshot()
  #expect(selected.installations[0].alias == manifests[0].origin.preferredAlias)
  #expect(selected.installations[1].alias == manifests[1].origin.fixedAlias)
  try await manager.removeInstallation(installed[0].id)
  #expect(try await manager.snapshot().installations.first?.alias == manifests[1].origin.preferredAlias)
}

private actor TerminalSaveFailureLibrary: SnapshotTestPersistence {
  var value = ModelLibrarySnapshot()
  var failNextTerminal = true
  func readLibrary() -> ModelLibrarySnapshot { value }
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) throws {
    if failNextTerminal, snapshot.operations.contains(where: { $0.phase == .failed }) {
      failNextTerminal = false
      throw MoxError(.storageFailed, "Injected terminal save failure")
    }
    value = snapshot
  }
}

@Test func unsavedDownloadFailureRemainsVisibleAndSameTaskCanRetry() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/terminal",
    revision: String(repeating: "f", count: 40)), files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "a", count: 64)))])
  let db = TerminalSaveFailureLibrary()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let id = try await manager.create(provider: .huggingFace,
    endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  try await manager.resume(id, source: FailingDomainSource())
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.operation(id).errorCode != "storageFailed", ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await manager.operation(id).phase == .failed)
  #expect(try await manager.operation(id).errorCode == "storageFailed")
  #expect(await db.readLibrary().operations.first?.phase == .downloading)
  // The terminal overlay is published just before the runner releases admission.
  let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
  while true {
    do { try await manager.resume(id, source: FailingDomainSource()); break }
    catch let error as MoxError where error.code == .busy && ContinuousClock.now < admissionDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  let retryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
  while await db.readLibrary().operations.first?.phase != .failed, ContinuousClock.now < retryDeadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await manager.operation(id).errorCode == "sourceFailed")
  #expect(await db.readLibrary().operations.first?.phase == .failed)
  await manager.shutdown()
}
