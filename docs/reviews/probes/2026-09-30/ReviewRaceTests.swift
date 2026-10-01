import Foundation
import Testing
import MoxDomain
@testable import MoxCore

private actor ReviewDB: ModelLibraryPersistence {
 var state = ModelLibrarySnapshot()
 var blocked = false
 var entered = false
 var waiter: CheckedContinuation<Void, Never>?
 func arm() { blocked = true }
 func readLibrary() -> ModelLibrarySnapshot { state }
 func saveLibrary(_ next: ModelLibrarySnapshot) async {
  if blocked { blocked = false; entered = true; await withCheckedContinuation { waiter = $0 } }
  state = next
 }
 func release() { waiter?.resume(); waiter = nil }
}
private actor ReviewSource: ModelFileSource {
 var calls = 0
 var waiters: [CheckedContinuation<Void, Never>] = []
 func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
  calls += 1
  await withCheckedContinuation { waiters.append($0) }
  throw MoxError(.connectionLost, "Probe ended")
 }
 func release() { let w = waiters; waiters.removeAll(); w.forEach { $0.resume() } }
}
@Test func reviewConcurrentResumeMustStartOneRunner() async throws {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: root) }
 let db = ReviewDB(); let source = ReviewSource()
 let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root), state: .init())
 let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/race", revision: String(repeating: "a", count: 40)), files: [.init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "b", count: 64)))])
 let id = try await manager.create(provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
 await db.arm()
 let first = Task { () -> Bool in do { try await manager.resume(id, source: source); return true } catch { return false } }
 while !(await db.entered) { await Task.yield() }
 let second = Task { () -> Bool in do { try await manager.resume(id, source: source); return true } catch { return false } }
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
