import CryptoKit
import Foundation
import Testing
import MoxDomain
@testable import MoxCore
private actor CommitFailureDB: SnapshotTestPersistence {
 var state = ModelLibrarySnapshot()
 var failInstallation = true
 func readLibrary() -> ModelLibrarySnapshot { state }
 func saveLibrary(_ value: ModelLibrarySnapshot) throws {
  if failInstallation && !value.installations.isEmpty {
   failInstallation = false
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
  try FileManager.default.copyItem(at: root.appendingPathComponent(file.path), to: destination.appendingPathComponent(file.path))
 }
}
@Test func reviewRetryAfterCommittedFilesMustRepairIndex() async throws {
 let model = try fixture()
 let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: model.directory) }
 let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil).map { url in
  let data = try Data(contentsOf: url)
  return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count), digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
 }
 let manifest = ArtifactManifest(origin: .init(registryID: UUID(), repository: "fixture/retry", revision: String(repeating: "b", count: 40)), files: files)
 let db = CommitFailureDB(); let source = CommitSource(model.directory)
 let artifacts = try ArtifactStore(root: root)
 let manager = DownloadManager(persistence: db, artifacts: artifacts)
 let id = try await manager.create(provider: .huggingFace, endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
 try await manager.resume(id, source: source)
 let deadline = ContinuousClock.now.advanced(by: .seconds(5))
 while try await manager.operation(id).phase != .failed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
 #expect(FileManager.default.fileExists(atPath: try artifacts.installedDirectory(for: manifest.origin).path))
 let before = await source.calls
 try await manager.resume(id, source: source)
 let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
 while try await manager.operation(id).phase.isActive && ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(10)) }
 let result = try await manager.operation(id)
 let after = await source.calls
 #expect(result.phase == .installed)
 #expect(after == before)
 await manager.shutdown()
}
