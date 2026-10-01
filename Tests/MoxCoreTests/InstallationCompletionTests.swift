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
@Test(arguments: [false, true]) func reviewRetryAfterCommittedFilesMustRepairIndex(
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
  try await manager.resume(id, source: source)
  let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
  while try await manager.operation(id).phase.isActive && ContinuousClock.now < secondDeadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  let result = try await manager.operation(id)
  let after = await source.calls
  #expect(result.phase == .installed)
  #expect(after == before)
  await manager.shutdown()
}

@Test(arguments: ["clean", "damaged", "conflict"])
func committedIndexFailureRecoversAfterRestartOrRejectsDamage(
  scenario: String
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
      registryID: UUID(), repository: "fixture/restart", revision: String(repeating: "c", count: 40)
    ), files: files)
  let db = CommitFailureDB()
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
  await manager.shutdown()
  if scenario == "damaged" {
    let file = try artifacts.installedDirectory(for: manifest.origin).appendingPathComponent(
      files[0].path)
    try Data("damaged".utf8).write(to: file)
  }
  if scenario == "conflict" {
    let alternative = ArtifactManifest(origin: manifest.origin, files: Array(files.reversed()))
    try JSONEncoder().encode(alternative).write(
      to: artifacts.installedDirectory(for: manifest.origin).appendingPathComponent(
        "mox-manifest.json"))
  }
  let damaged = scenario != "clean"
  let restarted = try await DownloadManager.open(persistence: db, artifacts: artifacts)
  await restarted.waitForRecovery()
  #expect(try await restarted.operation(id).phase == (damaged ? .failed : .installed))
  #expect((try await restarted.findInstallation(.origin(manifest.origin)) != nil) == !damaged)
  #expect(await source.calls == files.count)
  if damaged {
    try await restarted.resume(id, source: source)
    let until = ContinuousClock.now.advanced(by: .seconds(5))
    while try await restarted.operation(id).phase.isActive && ContinuousClock.now < until {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await restarted.operation(id).phase == .failed)
    #expect(await source.calls == files.count)
  }
  await restarted.shutdown()
}
