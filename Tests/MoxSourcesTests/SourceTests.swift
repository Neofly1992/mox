import Foundation
import MoxCore
import MoxDomain
import Testing

@testable import MoxSources

@Test func credentialsUseExactOrigin() throws {
  let origin = URL(string: "https://example.com")!
  #expect(SourceRedirectPolicy.sameOrigin(origin, URL(string: "https://example.com:443/file")))
  for target in [
    "https://other.example/file", "http://example.com/file", "https://example.com:444/file",
  ] {
    #expect(!SourceRedirectPolicy.sameOrigin(origin, URL(string: target)))
  }
}

@Test func unavailableKeychainCredentialFailsClosed() throws {
  let credentials = SourceCredentials()
  let reference = try credentials.reference(registryID: UUID(), endpoint: URL(string: "https://example.com")!)
  do {
    _ = try credentials.read(reference: reference)
    Issue.record("A nonexistent credential must not silently become anonymous access.")
  } catch let error as MoxError {
    #expect(error.code == .authenticationFailed)
  }
}

@Test func stagedCredentialDoesNotOverwriteCommittedCredential() throws {
  let credentials = SourceCredentials()
  let registryID = UUID()
  let endpoint = URL(string: "https://example.com")!
  let first = try credentials.save("first", registryID: registryID, endpoint: endpoint)
  defer { try? credentials.delete(reference: first) }
  let second = try credentials.save("second", registryID: registryID, endpoint: endpoint)
  defer { try? credentials.delete(reference: second) }
  #expect(first != second)
  #expect(try credentials.read(reference: first) == "first")
  #expect(try credentials.read(reference: second) == "second")
  try credentials.delete(reference: second)
  #expect(try credentials.read(reference: first) == "first")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOX_TEST_REAL_SOURCES"] == "1"))
func realModelScopeResolvesFixedSnapshotAndVerifiesConfig() async throws {
  let source = try ModelScopeSource()
  let manifest = try await source.resolve(registryID: UUID(), repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", selector: "master")
  #expect(manifest.origin.revision.count == 40)
  let metadata = try #require(try await source.resourceConfiguration(manifest))
  let weights = manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) {
    $0 + $1.bytes
  }
  let resources = try ModelResources(configuration: metadata, weightBytes: Int(weights))
  #expect(resources.assessment(maxTokens: 8, budgetBytes: Int.max).status == .recommended)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let config = try #require(manifest.files.first { $0.path == "config.json" })
  try await source.download(config, manifest: manifest, to: root)
  print("MODELSCOPE revision=\(manifest.origin.revision) files=\(manifest.files.count) configBytes=\(config.bytes)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOX_TEST_REAL_SOURCES"] == "1"))
func realHuggingFaceResolvesFixedSnapshot() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = try HuggingFaceSource(cacheDirectory: root)
  let manifest = try await source.resolve(registryID: UUID(), repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", selector: "main")
  #expect(manifest.origin.revision.count == 40)
  let metadata = try #require(try await source.resourceConfiguration(manifest))
  let weights = manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) {
    $0 + $1.bytes
  }
  let resources = try ModelResources(configuration: metadata, weightBytes: Int(weights))
  #expect(resources.assessment(maxTokens: 8, budgetBytes: Int.max).status == .recommended)
  #expect(manifest.files.contains { $0.path == "model.safetensors" })
  let staging = root.appendingPathComponent("staging")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let config = try #require(manifest.files.first { $0.path == "config.json" })
  try await source.download(config, manifest: manifest, to: staging)
  print("HF revision=\(manifest.origin.revision) files=\(manifest.files.count)")
}

@Test func redirectedCredentialsNeverCrossOriginOrDowngrade() throws {
  let origin = URL(string: "https://source.example")!
  let session = URLSession(configuration: .ephemeral)
  let task = session.dataTask(with: URLRequest(url: origin))
  let response = HTTPURLResponse(url: origin, statusCode: 302,
    httpVersion: nil, headerFields: ["Location": "https://cdn.example/file"])!
  let policy = SourceRedirectPolicy()
  final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    func set(_ request: URLRequest?) { lock.withLock { value = request } }
    func get() -> URLRequest? { lock.withLock { value } }
  }
  let captured = Capture()
  var remote = URLRequest(url: URL(string: "https://cdn.example/file")!)
  remote.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
  remote.setValue("session=secret", forHTTPHeaderField: "Cookie")
  policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
    newRequest: remote, completionHandler: { captured.set($0) })
  #expect(captured.get()?.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(captured.get()?.value(forHTTPHeaderField: "Cookie") == nil)
  remote.url = URL(string: "http://source.example/file")!
  policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
    newRequest: remote, completionHandler: { captured.set($0) })
  #expect(captured.get() == nil)
}

@Test func variantSelectsOneModelRootWithoutMixingOtherWeights() throws {
  #expect(ModelAssetSelection.includes("4bit/config.json", variant: "4bit"))
  #expect(ModelAssetSelection.includes("4bit/model.safetensors", variant: "4bit"))
  #expect(!ModelAssetSelection.includes("8bit/model.safetensors", variant: "4bit"))
  #expect(!ModelAssetSelection.includes("4bit/nested/model.safetensors", variant: "4bit"))
  let hash = ArtifactDigest.sha256(String(repeating: "a", count: 64))
  let files = [
    "4bit/config.json", "4bit/tokenizer.json", "4bit/tokenizer_config.json",
    "4bit/model.safetensors",
  ].map { ArtifactFile(path: $0, bytes: 1, digest: hash) }
  try ModelAssetSelection.validate(files, variant: "4bit")
}
