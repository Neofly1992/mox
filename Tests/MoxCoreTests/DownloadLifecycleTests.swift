import Foundation
import MoxDomain
import Testing

@testable import MoxCore

private actor ReviewDB: SnapshotTestPersistence {
  var state = ModelLibrarySnapshot()
  var blocked = false
  var entered = false
  var waiter: CheckedContinuation<Void, Never>?
  func arm() { blocked = true }
  func readLibrary() -> ModelLibrarySnapshot { state }
  func saveLibrary(_ next: ModelLibrarySnapshot) async {
    if blocked {
      blocked = false
      entered = true
      await withCheckedContinuation { waiter = $0 }
    }
    state = next
  }
  func release() {
    waiter?.resume()
    waiter = nil
  }
}
private actor ReviewSource: ModelFileSource {
  var calls = 0
  var waiters: [CheckedContinuation<Void, Never>] = []
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    calls += 1
    await withCheckedContinuation { waiters.append($0) }
    throw MoxError(.connectionLost, "Probe ended")
  }
  func release() {
    let w = waiters
    waiters.removeAll()
    w.forEach { $0.resume() }
  }
}
@Test func reviewConcurrentResumeMustStartOneRunner() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let db = ReviewDB()
  let source = ReviewSource()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/race", revision: String(repeating: "a", count: 40)),
    files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "b", count: 64)))
    ])
  let id = try await manager.create(
    provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  await db.arm()
  let first = Task { () -> Bool in
    do {
      try await manager.resume(id, source: source)
      return true
    } catch { return false }
  }
  while !(await db.entered) { await Task.yield() }
  let second = Task { () -> Bool in
    do {
      try await manager.resume(id, source: source)
      return true
    } catch { return false }
  }
  try await Task.sleep(for: .milliseconds(150))
  await db.release()
  let accepted = await [first.value, second.value].filter { $0 }.count
  try await Task.sleep(for: .milliseconds(150))
  #expect(accepted == 1)
  let transferCount = await source.calls
  #expect(transferCount == 1)
  await source.release()
  await manager.shutdown()
}

private struct CancellableSource: ModelFileSource {
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    try await Task.sleep(for: .seconds(60))
  }
}
@Test func cancelOwnsPendingDownloadAdmission() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let db = ReviewDB()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/cancel", revision: String(repeating: "a", count: 40)),
    files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "b", count: 64)))
    ])
  let id = try await manager.create(
    provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  await db.arm()
  let resume = Task { try await manager.resume(id, source: CancellableSource()) }
  while !(await db.entered) { await Task.yield() }
  let cancel = Task { try await manager.cancel(id) }
  await db.release()
  try await resume.value
  try await cancel.value
  #expect(try await manager.operation(id).phase == .cancelled)
  #expect(await db.state.operations.first?.phase == .cancelled)
  await manager.shutdown()
}
@Test func shutdownOwnsPendingDownloadAdmission() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let db = ReviewDB()
  let source = ReviewSource()
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root))
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/stop", revision: String(repeating: "a", count: 40)),
    files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "b", count: 64)))
    ])
  let id = try await manager.create(
    provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  await db.arm()
  let resume = Task { try await manager.resume(id, source: source) }
  while !(await db.entered) { await Task.yield() }
  let shutdown = Task { await manager.shutdown() }
  // Wait until shutdown has entered the actor before releasing persistence.
  await Task.yield()
  try await Task.sleep(for: .milliseconds(30))
  await db.release()
  await #expect(throws: MoxError.self) { try await resume.value }
  await shutdown.value
  #expect(await source.calls == 0)
  #expect(try await manager.operation(id).phase == .interrupted)
  await #expect(throws: MoxError.self) { try await manager.resume(id, source: source) }
}
