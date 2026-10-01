import CryptoKit
import Foundation
import MoxDomain
import Testing

@testable import MoxCore

private actor CommitFailureDB: SnapshotTestPersistence {
  var state = ModelLibrarySnapshot()
  var failInstallation = true
  let failAfterSaving: Bool
  init(failAfterSaving: Bool = false) { self.failAfterSaving = failAfterSaving }
  func seed(_ value: ModelLibrarySnapshot) {
    state = value
    failInstallation = false
  }
  func readLibrary() -> ModelLibrarySnapshot { state }
  func saveLibrary(_ value: ModelLibrarySnapshot) throws {
    if failInstallation && !value.installations.isEmpty {
      failInstallation = false
      if failAfterSaving { state = value }
      throw MoxError(.storageFailed, "Injected installation index failure")
    }
    state = value
  }
}
private actor CommitSource: ModelFileSource {
  let root: URL
  var calls = 0
  init(_ root: URL) { self.root = root }
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to destination: URL) throws {
    calls += 1
    try FileManager.default.copyItem(
      at: root.appendingPathComponent(file.path), to: destination.appendingPathComponent(file.path))
  }
}
@Test(arguments: [false, true]) func reviewRestartAfterUncertainIndexCommit(
  failAfterSaving: Bool
) async throws {
  let model = try fixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let files = try FileManager.default.contentsOfDirectory(
    at: model.directory, includingPropertiesForKeys: nil
  ).map { url in
    let data = try Data(contentsOf: url)
    return ArtifactFile(
      path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/retry", revision: String(repeating: "b", count: 40)),
    files: files)
  let db = CommitFailureDB(failAfterSaving: failAfterSaving)
  let source = CommitSource(model.directory)
  let artifacts = try ArtifactStore(root: root)
  let manager = DownloadManager(persistence: db, artifacts: artifacts)
  let id = try await manager.create(
    provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  try await manager.resume(id, source: source)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.operation(id).phase != .failed && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(
    FileManager.default.fileExists(
      atPath: try artifacts.installedDirectory(for: manifest.origin).path))
  let before = await source.calls
  await manager.shutdown()
  let reopened = try await DownloadManager.open(persistence: db, artifacts: artifacts)
  await reopened.waitForRecovery()
  let result = try await reopened.operation(id)
  let after = await source.calls
  #expect(result.phase == .installed)
  #expect(after == before)
  await reopened.shutdown()
}

@Test(arguments: [DownloadPhase.committing, .interrupted, .failed], [false, true])
func restartCompletesIndexedInstallationWithUnfinishedTask(
  phase: DownloadPhase, conflictingPlan: Bool
) async throws {
  let model = try fixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let artifacts = try ArtifactStore(root: root)
  let stagingID = UUID()
  let staging = try artifacts.stagingDirectory(for: stagingID)
  let files = try FileManager.default.contentsOfDirectory(
    at: model.directory, includingPropertiesForKeys: nil
  ).map { url in
    let data = try Data(contentsOf: url)
    try FileManager.default.copyItem(
      at: url, to: staging.appendingPathComponent(url.lastPathComponent))
    return ArtifactFile(
      path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/indexed",
      revision: String(repeating: "c", count: 40)), files: files)
  let directory = try artifacts.commit(operationID: stagingID, manifest: manifest)
  var item = ModelInstallation(path: directory.path, manifest: manifest, alias: "kept-alias")
  item.pinned = true
  item.samplingSettings = .init(maxTokens: 321)
  var operation = DownloadOperation(
    provider: .huggingFace,
    endpoint: URL(string: "https://huggingface.co")!,
    manifest: conflictingPlan
      ? ArtifactManifest(origin: manifest.origin, files: Array(files.reversed())) : manifest)
  operation.phase = phase
  operation.errorCode = "storageFailed"
  operation.failureDomain = "injected"
  operation.failureSystemCode = 19
  let db = CommitFailureDB()
  // This fixture represents a durable index and an incomplete task, after process exit.
  await db.seed(.init(installations: [item], operations: [operation]))
  let manager = try await DownloadManager.open(persistence: db, artifacts: artifacts)
  await manager.waitForRecovery()
  let repaired = try await manager.operation(operation.id)
  if conflictingPlan {
    #expect(repaired.phase != .installed)
    #expect(repaired.errorCode == "storageFailed")
    #expect(try await manager.findInstallation(.id(item.id))?.alias == item.alias)
    await manager.shutdown()
    return
  }
  #expect(repaired.phase == .installed)
  #expect(repaired.verifiedBytes == files.reduce(0) { $0 + $1.bytes })
  #expect(
    repaired.errorCode == nil && repaired.failureDomain == nil && repaired.failureSystemCode == nil)
  let kept = try #require(try await manager.findInstallation(.id(item.id)))
  #expect(kept.alias == item.alias && kept.pinned && kept.samplingSettings == item.samplingSettings)
  await manager.shutdown()
  let second = try await DownloadManager.open(persistence: db, artifacts: artifacts)
  await second.waitForRecovery()
  #expect(try await second.operation(operation.id).phase == .installed)
  #expect(try await second.installations(offset: 0).count == 1)
  await second.shutdown()
}
