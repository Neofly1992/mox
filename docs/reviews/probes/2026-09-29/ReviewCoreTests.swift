import Foundation
import CryptoKit
import MoxDomain
import Testing
@testable import MoxCore

@Test func reviewExplicitLoadCanRetryAfterTransientFailure() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend(failures: 1)
  let core = runtime(backend)
  do { try await core.load(model: model); Issue.record("First load should fail") } catch {}
  do { try await core.load(model: model) }
  catch { Issue.record("Explicit retry still uses failed loader: \(error)") }
  #expect(await backend.loads == 2)
  await core.shutdown()
}

private actor ReviewGate {
  var arrived = false
  var released = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    arrived = true
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor ReviewPersistence: ModelLibraryPersistence {
  var value = ModelLibrarySnapshot()
  let gate: ReviewGate
  var blockNext = false
  init(gate: ReviewGate) { self.gate = gate }
  func readLibrary() -> ModelLibrarySnapshot { value }
  func arm() { blockNext = true }
  func saveLibrary(_ next: ModelLibrarySnapshot) async {
    if blockNext { blockNext = false; await gate.wait() }
    value = next
  }
}
private struct ReviewSource: ModelFileSource {
  let directory: URL
  let gate: ReviewGate
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    await gate.wait()
    try FileManager.default.copyItem(at: directory.appendingPathComponent(file.path),
      to: root.appendingPathComponent(file.path))
  }
}
@Test func reviewConfigSaveMustNotStrandActiveDownload() async throws {
  let model = try fixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: model.directory); try? FileManager.default.removeItem(at: root) }
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil).map { url in
    let data = try Data(contentsOf: url)
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count),
      digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "review/model",
    revision: String(repeating: "a", count: 40)), files: files)
  let saveGate = ReviewGate()
  let fileGate = ReviewGate()
  let db = ReviewPersistence(gate: saveGate)
  let manager = DownloadManager(persistence: db, artifacts: try ArtifactStore(root: root), state: .init())
  let id = try await manager.create(provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  try await manager.resume(id, source: ReviewSource(directory: model.directory, gate: fileGate))
  while !(await fileGate.arrived) { await Task.yield() }
  await db.arm()
  let config = Task { try await manager.setPublicAPIEnabled(true) }
  while !(await saveGate.arrived) { await Task.yield() }
  await fileGate.release()
  // Keep the persistence gate held while the completed download tries to publish progress.
  try await Task.sleep(for: .milliseconds(300))
  await saveGate.release()
  _ = try await config.value
  let phase = await manager.snapshot().operations.first?.phase
  #expect(phase != .downloading, "Runner has stopped but persisted phase still claims downloading")
  await #expect(throws: Never.self) { try await manager.resume(id, source: ReviewSource(directory: model.directory, gate: fileGate)) }
  await manager.shutdown()
}
