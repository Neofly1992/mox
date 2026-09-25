import CryptoKit
import Foundation
import MoxDomain
import Testing
@testable import MoxCore

private let artifactOrigin = ArtifactOrigin(
  registryID: UUID(uuidString: "B387C243-D9B9-4CFB-91DD-829B71571049")!,
  repository: "org/model", revision: String(repeating: "a", count: 40))

@Test func artifactPathsRejectTraversalAndAmbiguousLayouts() throws {
  for path in ["", "/root", "../x", "a/../b", "a//b", "a\\b", "a:b", "a\0b", "mox-manifest.json"] {
    #expect(throws: MoxError.self) { try ArtifactValidation.relativePath(path) }
  }
  try ArtifactValidation.relativePath("weights/model-00001.safetensors")
  let hash = ArtifactDigest.sha256(String(repeating: "a", count: 64))
  for paths in [["A.json", "a.json"], ["a", "a/b"], ["é.json", "e\u{301}.json"]] {
    let manifest = ArtifactManifest(
      origin: artifactOrigin, files: paths.map { ArtifactFile(path: $0, bytes: 1, digest: hash) })
    #expect(throws: MoxError.self) { try ArtifactValidation.validate(manifest) }
  }
}

@Test func artifactIdentityExcludesAccessEndpointAndIncludesExactVersion() throws {
  let id = try ArtifactValidation.identifier(for: artifactOrigin)
  #expect(id.count == 64)
  #expect(id == (try ArtifactValidation.identifier(for: artifactOrigin)))
  let other = ArtifactOrigin(
    registryID: artifactOrigin.registryID, repository: artifactOrigin.repository,
    revision: String(repeating: "b", count: 40))
  #expect(id != (try ArtifactValidation.identifier(for: other)))
}

@Test func diskPreflightAccountsForTemporaryLargestFile() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ArtifactStore(root: root)
  let digest = ArtifactDigest.sha256(String(repeating: "a", count: 64))
  let manifest = ArtifactManifest(origin: artifactOrigin, files: [
    .init(path: "a", bytes: 100, digest: digest),
    .init(path: "b", bytes: 80, digest: digest)])
  #expect(throws: MoxError.self) { try store.checkAvailableSpace(for: manifest, availableBytes: 279) }
  try store.checkAvailableSpace(for: manifest, availableBytes: 280)
  let plan = try store.spacePlan(for: manifest)
  #expect(plan.totalBytes == 180)
  #expect(plan.peakBytes == 280)
}

@Test func artifactDigestDistinguishesGitBlobFromPlainSHA1AndRejectsSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let content = Data("hello\n".utf8)
  try content.write(to: root.appendingPathComponent("file"))
  let git = ArtifactFile(path: "file", bytes: 6, digest: .gitBlobSHA1("ce013625030ba8dba906f756967f9e9ca394464a"))
  try ArtifactValidation.verify(git, in: root)
  let plain = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
  #expect(throws: MoxError.self) {
    try ArtifactValidation.verify(.init(path: "file", bytes: 6, digest: .gitBlobSHA1(plain)), in: root)
  }
  let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
  try ArtifactValidation.verify(.init(path: "file", bytes: 6, digest: .sha256(sha)), in: root)
  #expect(throws: MoxError.self) {
    try ArtifactValidation.verify(.init(path: "file", bytes: 5, digest: .sha256(sha)), in: root)
  }
  try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("file"))
  #expect(throws: MoxError.self) {
    try ArtifactValidation.verify(.init(path: "link", bytes: 6, digest: .sha256(sha)), in: root)
  }
}

@Test(arguments: [false, true])
func artifactCommitFailureLeavesRecoverableFiles(afterRename: Bool) throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ArtifactStore(root: root)
  let operation = UUID()
  let staging = try store.stagingDirectory(for: operation)
  let files = try FileManager.default.contentsOfDirectory(at: model.directory, includingPropertiesForKeys: nil)
  let manifest = try ArtifactManifest(origin: artifactOrigin, files: files.map { url in
    let data = try Data(contentsOf: url)
    try data.write(to: staging.appendingPathComponent(url.lastPathComponent))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ArtifactFile(path: url.lastPathComponent, bytes: Int64(data.count), digest: .sha256(hash))
  })
  struct SimulatedCrash: Error {}
  #expect(throws: SimulatedCrash.self) {
    _ = try store.commit(operationID: operation, manifest: manifest) { boundary in
      switch boundary {
      case .manifestWritten: if !afterRename { throw SimulatedCrash() }
      case .directoryRenamed: if afterRename { throw SimulatedCrash() }
      }
    }
  }
  let reopened = try ArtifactStore(root: root)
  if afterRename {
    #expect(try reopened.committedManifests() == [manifest])
  } else {
    #expect(try reopened.committedManifests().isEmpty)
    _ = try reopened.commit(operationID: operation, manifest: manifest)
    #expect(try reopened.committedManifests() == [manifest])
  }
  let installed = try reopened.installedDirectory(for: manifest.origin)
  _ = try LocalModel(path: installed.path)
  try Data("corrupt".utf8).write(to: installed.appendingPathComponent("config.json"))
  #expect(throws: MoxError.self) { _ = try reopened.committedManifests() }
  #expect(FileManager.default.fileExists(atPath: installed.path))
}
