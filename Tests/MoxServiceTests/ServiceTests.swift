import CryptoKit
import Darwin
import Foundation
import MoxBootstrap
import MoxChat
import MoxClient
import MoxDomain
import MoxPersistence
import MoxProtocol
import MoxServer
import Security
import SwiftData
import Testing

@testable import MoxCore

func temporaryRoot() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mox M2 测试 \(UUID())")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
func serviceModel() throws -> LocalModel {
  let root = try temporaryRoot()
  try Data(
    #"{"model_type":"qwen2","hidden_size":16,"num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,"max_position_embeddings":32768,"vocab_size":100}"#
      .utf8
  ).write(to: root.appendingPathComponent("config.json"))
  for name in ["tokenizer_config.json", "tokenizer.json"] {
    try Data("{}".utf8).write(to: root.appendingPathComponent(name))
  }
  let header = Data(#"{"test":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
  var size = UInt64(header.count).littleEndian
  var weights = withUnsafeBytes(of: &size) { Data($0) }
  weights.append(header)
  weights.append(Data(repeating: 0, count: 4))
  try weights.write(to: root.appendingPathComponent("model.safetensors"))
  return try LocalModel(path: root.path)
}
func committedServiceInstallation(
  model: LocalModel, origin: ArtifactOrigin, artifacts: ArtifactStore
) throws -> ModelInstallation {
  let operation = UUID()
  let staging = try artifacts.stagingDirectory(for: operation)
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
  let manifest = ArtifactManifest(origin: origin, files: files)
  let directory = try artifacts.commit(operationID: operation, manifest: manifest)
  return ModelInstallation(path: directory.path, manifest: manifest, alias: origin.preferredAlias)
}

struct ServiceBackend: RuntimeBackend {
  var count = 50
  var delay: Duration = .milliseconds(2)
  var text = "你e\u{301}👨‍👩‍👧‍👦\n"
  var onGenerate: (@Sendable (UUID) async -> Void)? = nil
  func load(_ model: LocalModel) async throws -> any LoadedModel {
    try await Task.sleep(for: .milliseconds(100))
    return Loaded(count: count, delay: delay, text: text, onGenerate: onGenerate)
  }
  struct Loaded: LoadedModel {
    let count: Int
    let delay: Duration
    let text: String
    let onGenerate: (@Sendable (UUID) async -> Void)?
    func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
      -> BackendResult
    {
      await onGenerate?(request.id)
      for _ in 0..<count {
        if output.isCancelled { break }
        if !output.emit(.contentDelta(text)) { break }
        try? await Task.sleep(for: delay)
      }
      await Task.detached { try? await Task.sleep(for: .milliseconds(30)) }.value
      return .init(reason: output.isCancelled ? .cancelled : .stop)
    }
    func unload() async {}
  }
}
func withService(
  backend: ServiceBackend = ServiceBackend(), rootIdentity: String = "fixture",
  downloads: DownloadManager? = nil, sources: (any ModelSourceFactory)? = nil,
  launchSampling: SamplingSettings = .init(),
  _ body: (ServiceClient, RuntimeCoordinator) async throws -> Void
) async throws {
  let identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: rootIdentity, ownership: .foreground)
  let token = try ServiceFiles.token()
  let runtime = RuntimeCoordinator(backend: backend, policy: .init(budgetBytes: 512 * 1024 * 1024))
  let service = InferenceService(
    identity: identity, token: token, runtime: runtime,
    downloads: downloads, sources: sources, launchSampling: launchSampling)
  if let downloads {
    await service.attachPublicAPI(
      PublicAPIManager(
        service: service,
        downloads: downloads, rootIdentity: rootIdentity))
  }
  let ready = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let server = Task {
    try await PrivateServer(service: service).run { ready.continuation.yield($0) }
  }
  var iterator = ready.stream.makeAsyncIterator()
  guard let port = await iterator.next() else { throw MoxError(.connectionLost, "No port") }
  let client = ServiceClient(
    discovery: Discovery(
      identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: token))
  do { try await body(client, runtime) } catch {
    await service.shutdown()
    server.cancel()
    _ = try? await server.value
    throw error
  }
  await service.shutdown()
  server.cancel()
  _ = try? await server.value
  #expect(await runtime.snapshot().reservedBytes == 0)
}
@Test func samplingSettingsResolveAndSurviveReopen() async throws {
  let root = try temporaryRoot()
  let model = try serviceModel()
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let store = try await RuntimeStore.open(root: root)
  let manager = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  try await withService(
    downloads: manager,
    launchSampling: .init(maxTokens: 700, temperature: 0.3)
  ) { client, _ in
    let item = try await client.importModel(path: model.directory.path, alias: "sample-test")
    let initial = try await client.library().configuration.revision
    _ = try await client.setGlobalSampling(
      .init(
        expectedRevision: initial,
        settings: .init(maxTokens: 900, topP: 0.8)))
    await #expect(throws: MoxError.self) {
      _ = try await client.setGlobalSampling(
        .init(
          expectedRevision: initial,
          settings: .init(maxTokens: 1000)))
    }
    let globalRevision = try await client.library().configuration.revision
    _ = try await client.setModelSampling(
      item.id,
      .init(
        expectedRevision: globalRevision,
        settings: .init(maxTokens: 500)))
    let modelRevision = try await client.library().configuration.revision
    let pinned = try await client.setModelPinned(
      item.id,
      .init(expectedRevision: modelRevision, pinned: true))
    #expect(pinned.pinned)
    let effective = try await client.resolveSampling(
      .init(
        model: .init(kind: "installedAlias", path: "sample-test"),
        explicit: .init(temperature: 0)))
    #expect(effective.maxTokens == 500 && effective.maxTokensSource == .model)
    #expect(effective.temperature == 0 && effective.temperatureSource == .request)
    #expect(effective.topP == 0.8 && effective.topPSource == .global)
    let launched = try await client.resolveSampling(
      .init(
        model: .init(kind: "localDirectory", path: "/unused")))
    #expect(launched.maxTokens == 700 && launched.maxTokensSource == .launch)
  }
  let reopenedStore = try await RuntimeStore.open(root: root)
  let reopened = try await reopenedStore.readLibrary()
  #expect(reopened.configuration.globalSampling.maxTokens == 900)
  #expect(reopened.installations.first?.samplingSettings.maxTokens == 500)
  #expect(reopened.installations.first?.pinned == true)
}
@Test func activeDownloadSummaryIncludesOperationsBeyondFirstPage() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "fixture/model",
      revision: String(repeating: "d", count: 40)),
    files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "e", count: 64)))
    ])
  var operations = (0...ModelLibraryPage.pageSize).map { _ in
    DownloadOperation(
      provider: .huggingFace,
      endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  }
  operations[ModelLibraryPage.pageSize].phase = .downloading
  let snapshot = ModelLibrarySnapshot(operations: operations)
  #expect(!ModelLibraryPage(snapshot).operations.contains { $0.phase.isActive })
  let store = try await RuntimeStore.open(root: root)
  try await store.saveLibrary(snapshot)
  let manager = DownloadManager(persistence: store, artifacts: try ArtifactStore(root: root))
  let service = InferenceService(
    identity: .init(
      pid: getpid(), uid: getuid(),
      rootIdentity: "fixture", ownership: .foreground), token: "fixture",
    runtime: RuntimeCoordinator(
      backend: ServiceBackend(),
      policy: .init(budgetBytes: 512 * 1024 * 1024)), downloads: manager)
  #expect(try await service.snapshot().activeDownloads == 1)
}
@Test func privateBodyLimitsCloseUnfinishedChunkedConnections() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let manager = DownloadManager(persistence: store, artifacts: try ArtifactStore(root: root))
  try await withService(downloads: manager) { client, _ in
    for (path, bytes) in [
      ("/mox/v1/models/import", 16_385),
      ("/mox/v1/public-api", 1_025),
    ] {
      try await Task.detached {
        let peer = try SocketPeer(client: client)
        let head =
          "POST \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(client.discovery.token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        let chunk =
          String(bytes, radix: 16) + "\r\n" + String(repeating: "x", count: bytes) + "\r\n"
        try peer.send(Data((head + chunk).utf8))
        let response = try peer.receiveHead()
        #expect(response.contains(" 413 "))
        #expect(response.lowercased().contains("connection: close"))
        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = 0
        repeat { received = recv(peer.fd, &buffer, buffer.count, 0) } while received > 0
        #expect(received == 0)
      }.value
    }
  }
}
@Test func managementFailuresReachRedactedDiagnostics() async throws {
  try await withService { client, _ in
    await #expect(throws: MoxError.self) {
      _ = try await client.importModel(
        path: "/private/example/token-sensitive-model", alias: "fixture")
    }
    let events = try await client.diagnosticEvents()
    #expect(events.contains { $0.stage == "model.import" && $0.code == "shuttingDown" })
    let exported = String(decoding: try Wire.encode(events), as: UTF8.self)
    #expect(!exported.contains("token-sensitive-model"))
  }
}
func serviceRequest() throws -> GenerationRequest {
  try GenerationRequest(
    messages: [.init(role: .user, text: "fixture-private-prompt")],
    sampling: Sampling(maxTokens: 128))
}

@Test func concurrentPublicAPITogglesKeepStoredAndLiveStateAligned() async throws {
  let root = try temporaryRoot()
  let identity = UUID().uuidString
  defer {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.mox.public-api",
      kSecAttrAccount as String: "dev.mox.public-api.\(identity)",
    ]
    SecItemDelete(query as CFDictionary)
    try? FileManager.default.removeItem(at: root)
  }
  let store = try await RuntimeStore.open(root: root)
  let downloads = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  let runtime = RuntimeCoordinator(
    backend: ServiceBackend(),
    policy: .init(budgetBytes: 512 * 1024 * 1024))
  let service = InferenceService(
    identity: .init(
      pid: getpid(), uid: getuid(),
      rootIdentity: identity, ownership: .foreground), token: try ServiceFiles.token(),
    runtime: runtime, downloads: downloads)
  let manager = PublicAPIManager(service: service, downloads: downloads, rootIdentity: identity)
  await service.attachPublicAPI(manager)
  for _ in 0..<4 {
    let enable = Task { try await manager.setEnabled(true) }
    let disable = Task { try await manager.setEnabled(false) }
    _ = try await enable.value
    _ = try await disable.value
    let saved = try await downloads.snapshot().configuration.publicAPIEnabled
    let live = await manager.status()
    #expect(live.enabled == saved)
    #expect(live.enabled == (live.endpoint != nil))
  }
  await service.shutdown()
}

private final class CredentialProbe: ModelSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  private var selected: (URL, String?)?
  func saveCredential(_ value: String, registryID: UUID, endpoint: URL) throws -> String {
    let reference = UUID().uuidString
    lock.withLock { values[reference] = value }
    return reference
  }
  func deleteCredential(reference: String) throws {
    _ = lock.withLock { values.removeValue(forKey: reference) }
  }
  func make(provider: ModelProvider, endpoint: URL, credentialReference: String?) throws
    -> any ResolvedModelSource
  {
    lock.withLock { selected = (endpoint, credentialReference) }
    return ProbeSource()
  }
  func value(_ reference: String) -> String? { lock.withLock { values[reference] } }
  var lastSelection: (URL, String?)? { lock.withLock { selected } }
  var count: Int { lock.withLock { values.count } }
  private struct ProbeSource: ResolvedModelSource {
    func resolve(registryID: UUID, repository: String, selector: String, variant: String)
      async throws
      -> ArtifactManifest
    {
      throw MoxError(.invalidParameters, "Not used by this test.")
    }
    func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
      throw MoxError(.invalidParameters, "Not used by this test.")
    }
  }
}

@Test func libraryRecordsReopenInInstallationAndOperationOrder() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let first = ModelInstallation(path: "/tmp/first", manifest: nil, alias: "first")
  let second = ModelInstallation(path: "/tmp/second", manifest: nil, alias: "second")
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "owner/model",
      revision: String(repeating: "a", count: 40)),
    files: [
      .init(path: "config.json", bytes: 2, digest: .sha256(String(repeating: "b", count: 64)))
    ])
  let operation = DownloadOperation(
    provider: .huggingFace,
    endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
  let ordered = ModelLibrarySnapshot(installations: [second, first], operations: [operation])
  try await store.saveLibrary(ordered)
  let reopened = try await RuntimeStore.open(root: root)
  let read = try await reopened.readLibrary()
  #expect(read.installations.map(\.id) == [second.id, first.id])
  #expect(read.operations.map(\.id) == [operation.id])
  var changed = read
  changed.operations[0].verifiedBytes = 1
  try await reopened.saveLibrary(changed)
  let again = try await RuntimeStore.open(root: root)
  #expect(try await again.readLibrary().operations[0].verifiedBytes == 1)
  #expect(try await again.readLibrary().installations.map(\.id) == [second.id, first.id])
}

@Test func largeLibraryKeepsManagementResponsesBounded() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  var files = (0..<9_997).map { index in
    ArtifactFile(
      path: String(format: "model-%05d.safetensors", index), bytes: 64,
      digest: .sha256(String(repeating: "a", count: 64)))
  }
  files += ["config.json", "tokenizer.json", "tokenizer_config.json"].map {
    ArtifactFile(path: $0, bytes: 64, digest: .sha256(String(repeating: "a", count: 64)))
  }
  let manifest = ArtifactManifest(
    origin: .init(
      registryID: UUID(), repository: "owner/model",
      revision: String(repeating: "b", count: 40)), files: files)
  var library = ModelLibrarySnapshot(
    installations: (0..<60).map {
      ModelInstallation(path: model.directory.path, manifest: nil, alias: "local-\($0)")
    },
    operations: [
      DownloadOperation(
        provider: .huggingFace,
        endpoint: URL(string: "https://huggingface.co")!, manifest: manifest)
    ])
  #expect(try JSONEncoder().encode(library).count > 1_048_576)
  let store = try await RuntimeStore.open(root: root)
  try await store.saveLibrary(library)
  let downloads = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  try await withService(downloads: downloads) { client, _ in
    let first = try await client.library()
    #expect(first.installations.count == ModelLibraryPage.pageSize)
    #expect(first.totalInstallations == 60)
    #expect(first.operations.first?.fileCount == 10_000)
    let second = try await client.library(installationOffset: ModelLibraryPage.pageSize)
    #expect(second.installations.count == ModelLibraryPage.pageSize)
    #expect(second.installations.first?.id != first.installations.first?.id)
    let operation = try await client.download(library.operations[0].id)
    #expect(operation.fileCount == 10_000)
    let configuration = try await client.setDefaultRegistry(
      .init(
        expectedRevision: first.configuration.revision,
        registryID: first.configuration.defaultRegistryID))
    #expect(configuration.revision == first.configuration.revision + 1)
    let removed = try await client.removeModel(first.installations[0].id)
    #expect(removed.totalInstallations == 59)
  }
}

@Test func mirrorPullUsesOnlyMirrorCredential() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let downloads = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  let credentials = CredentialProbe()
  try await withService(downloads: downloads, sources: credentials) { client, _ in
    let initial = try await client.library()
    let origin = URL(string: "https://source.example")!
    let mirror = URL(string: "https://mirror.example")!
    let registry = ModelRegistry(
      id: UUID(), name: "Private mirror", provider: .modelScope,
      origin: origin, mirror: mirror)
    let updated = try await client.updateRegistry(
      .init(
        expectedRevision: initial.configuration.revision, registry: registry,
        credential: "origin-secret", mirrorCredential: "mirror-secret"))
    let saved = try #require(updated.registries.first { $0.id == registry.id })
    let originReference = try #require(saved.credentialReference)
    let mirrorReference = try #require(saved.mirrorCredentialReference)
    #expect(originReference != mirrorReference)
    await #expect(throws: MoxError.self) {
      _ = try await client.planPull(
        .init(
          provider: .modelScope, endpoint: mirror,
          registryID: registry.id, repository: "owner/model", selector: "master", variant: ""))
    }
    let selected = try #require(credentials.lastSelection)
    #expect(selected.0 == mirror)
    #expect(selected.1 == mirrorReference)
    #expect(credentials.value(selected.1!) == "mirror-secret")
  }
}

@Test func staleSourceUpdateCannotReplaceCommittedCredential() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let downloads = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  let credentials = CredentialProbe()
  try await withService(downloads: downloads, sources: credentials) { first, _ in
    let second = ServiceClient(discovery: first.discovery)
    let initial = try await first.library()
    let registry = ModelRegistry(
      id: UUID(), name: "Custom", provider: .huggingFace,
      origin: URL(string: "https://example.com")!)
    let committed = try await first.updateRegistry(
      .init(
        expectedRevision: initial.configuration.revision, registry: registry,
        credential: "committed"))
    let reference = try #require(
      committed.registries.first(where: { $0.id == registry.id })?.credentialReference)
    await #expect(throws: MoxError.self) {
      _ = try await second.updateRegistry(
        .init(
          expectedRevision: initial.configuration.revision, registry: registry,
          credential: "stale"))
    }
    #expect(credentials.value(reference) == "committed")
    #expect(credentials.count == 1)
    let current = try await first.library()
    #expect(
      current.configuration.registries.first(where: { $0.id == registry.id })?.credentialReference
        == reference)
    let replaced = try await second.updateRegistry(
      .init(
        expectedRevision: current.configuration.revision, registry: registry,
        credential: "replacement"))
    let newReference = try #require(
      replaced.registries.first(where: { $0.id == registry.id })?.credentialReference)
    #expect(newReference != reference)
    #expect(credentials.value(reference) == nil)
    #expect(credentials.value(newReference) == "replacement")
  }
}

@Test func activeGenerationRejectsDeletionUntilLeaseEnds() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let downloads = DownloadManager(
    persistence: store,
    artifacts: try ArtifactStore(root: root.appendingPathComponent("models")))
  try await withService(
    backend: ServiceBackend(count: 10_000, delay: .milliseconds(2)),
    downloads: downloads
  ) { client, runtime in
    let installation = try await client.importModel(path: model.directory.path, alias: "busy-model")
    let request = try serviceRequest()
    let generation = try client.generate(path: model.directory.path, request: request)
    let consumer = Task { for try await _ in generation.events {} }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await runtime.snapshot().activeLeases == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runtime.snapshot().activeLeases == 1)
    do {
      _ = try await client.removeModel(installation.id)
      Issue.record("A model with an active generation lease must not be removed.")
    } catch let error as MoxError { #expect(error.code == .busy) }
    #expect(FileManager.default.fileExists(atPath: model.directory.path))
    #expect(try await client.model(installation.id).id == installation.id)
    generation.disconnect()
    _ = try? await consumer.value
    while await runtime.snapshot().activeLeases != 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runtime.snapshot().activeLeases == 0)
    let removed = try await client.removeModel(installation.id)
    #expect(!removed.installations.contains { $0.id == installation.id })
    #expect(FileManager.default.fileExists(atPath: model.directory.path))
  }
}

@Test func installedAliasResolvesToFrozenModelPath() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let origin = ArtifactOrigin(
    registryID: UUID(), repository: "fixture/model",
    revision: String(repeating: "a", count: 40))
  let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
  let installation = try committedServiceInstallation(
    model: model, origin: origin, artifacts: artifacts)
  let store = try await RuntimeStore.open(root: root)
  try await store.commit(.init(installations: [installation]))
  let downloads = DownloadManager(persistence: store, artifacts: artifacts)
  try await withService(downloads: downloads) { client, _ in
    let remote = try client.generate(
      model: .init(
        kind: "installedAlias",
        path: origin.preferredAlias), request: serviceRequest())
    var terminal = false
    for try await event in remote.events {
      if event.payload.isTerminal { terminal = true }
    }
    #expect(terminal)
    #expect(await remote.waitUntilStopped())
  }
}

@Test func httpStreamCancelReuseAndIdentity() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService { client, runtime in
    #expect(try await client.identity() == client.discovery.identity)
    let r = try serviceRequest()
    let first = try client.generate(path: model.directory.path, request: r)
    var events: [GenerationEvent] = []
    for try await e in first.events {
      events.append(e)
      if case .phase("loading") = e.payload { first.cancel() }
    }
    await first.waitUntilStopped()
    #expect(events.map(\.sequence) == Array(0..<events.count))
    if case .finished(.cancelled) = events.last?.payload {
    } else {
      Issue.record("Expected cancelled terminal")
    }
    #expect(await runtime.snapshot().activeLeases == 0)
    #expect(try await client.cancel(r.id).terminal != nil)
    let duplicate = try client.generate(path: model.directory.path, request: r)
    await #expect(throws: MoxError.self) { for try await _ in duplicate.events {} }
    let next = try client.generate(path: model.directory.path, request: serviceRequest())
    var text = ""
    for try await e in next.events {
      if case .contentDelta(let chunk) = e.payload { text += chunk }
    }
    #expect(text == String(repeating: "你e\u{301}👨‍👩‍👧‍👦\n", count: 50))
    var wrong = client.discovery
    wrong.token = String(repeating: "a", count: 64)
    await #expect(throws: MoxError.self) {
      _ = try await ServiceClient(discovery: wrong).identity()
    }
  }
}
@Test func httpDisconnectAndPreAggregationLimit() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService { client, runtime in
    let generation = try client.generate(path: model.directory.path, request: serviceRequest())
    var iterator = generation.events.makeAsyncIterator()
    _ = try await iterator.next()
    generation.disconnect()
    try await Task.sleep(for: .milliseconds(300))
    #expect(await runtime.snapshot().activeLeases == 0)
    let response = try await Task.detached {
      let peer = try SocketPeer(client: client)
      // Do not send the body: prove rejection happens from the declared length alone.
      try peer.send(SocketPeer.generationHead(client: client, contentLength: Wire.bodyLimit + 1))
      return try peer.receiveHead()
    }.value
    #expect(response.hasPrefix("HTTP/1.1 413"))
    #expect(try await client.state().serviceState == "running")
  }
}
@Test func discoveryLocksPermissionsAndIdentity() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let lock = try files.lock()
  #expect(throws: MoxError.self) { _ = try files.lock() }
  let identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: files.rootIdentity, ownership: .foreground)
  let d = Discovery(
    identity: identity, privateEndpoint: "http://127.0.0.1:12345", token: try ServiceFiles.token())
  try files.publish(d)
  #expect(try files.read()?.identity == identity)
  files.remove(instanceID: UUID())
  #expect(try files.read() != nil)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o644],
    ofItemAtPath: files.run.appendingPathComponent("discovery.json").path)
  #expect(throws: MoxError.self) { _ = try files.read() }
  withExtendedLifetime(lock) {}
}
@Test func swiftDataRetryBranchAndRecovery() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await ConversationStore.open(root: root)
  let cid = try await store.create(modelPath: "/fixture")
  let a = try await store.begin(
    conversationID: cid, prompt: "hello", modelPath: "/fixture", sampling: Sampling())
  try await store.checkpoint(
    attemptID: a.attemptID, instanceID: nil, text: "world", status: "stop", sequence: 2, usage: nil,
    errorCode: nil)
  let b = try await store.begin(
    conversationID: cid, prompt: "second", modelPath: "/fixture", sampling: Sampling())
  #expect(b.request.messages.count == 3)
  try await store.checkpoint(
    attemptID: b.attemptID, instanceID: nil, text: "partial", status: "cancelled", sequence: 1,
    usage: nil, errorCode: nil)
  let retry = try await store.begin(
    conversationID: cid, prompt: "ignored", modelPath: "/fixture", sampling: Sampling(),
    retryOf: b.attemptID)
  #expect(retry.request.messages.count == 3)
  #expect(try retry.request.messages.last?.text() == "second")
  let snapshots = try await store.testSnapshots()
  #expect(snapshots.first?.attempts.count == 3)
  #expect(snapshots.first?.attempts[1].reply == "partial")
  #expect(snapshots.first?.selectedLeafID == a.attemptID)
  await #expect(throws: (any Error).self) { _ = try await ConversationStore.open(root: root) }
}
@Test func strictWireRejectsUnknownFields() throws {
  let body = try Wire.encode(GenerateBody(path: "/fixture", request: serviceRequest()))
  var json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  json["tools"] = []
  #expect(throws: MoxError.self) {
    _ = try GenerateBody.decode(JSONSerialization.data(withJSONObject: json))
  }
}

@Test func requestStateEncodesAndValidatesCancellationBarrier() throws {
  var state = RequestState(requestID: UUID(), modelID: "fixture", stopping: true)
  var json = try #require(JSONSerialization.jsonObject(with: Wire.encode(state)) as? [String: Any])
  #expect(json["state"] as? String == "stopping")
  json["state"] = "stopped"
  #expect(throws: MoxError.self) {
    _ = try Wire.decode(RequestState.self, JSONSerialization.data(withJSONObject: json))
  }
  state.terminal = EventFrame(
    instanceID: UUID(),
    event: .init(requestID: state.requestID, sequence: 0, payload: .finished(.cancelled)))
  #expect(try Wire.decode(RequestState.self, Wire.encode(state)).state == "stopped")
}

@Test func browserOriginsCannotReachPrivateOperations() async throws {
  try await withService { client, runtime in
    var request = try client.request("/state", method: "GET")
    request.setValue("http://localhost:9999", forHTTPHeaderField: "Origin")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 403)
    #expect(try Wire.decode(ErrorEnvelope.self, data).error.code == .authenticationFailed)
    #expect(await runtime.snapshot().activeLeases == 0)
    #expect(try await client.identity() == client.discovery.identity)
  }
}

private final class SaveFailureSwitch: @unchecked Sendable {
  let lock = NSLock()
  private var enabled = false
  func set(_ value: Bool) { lock.withLock { enabled = value } }
  func check() throws {
    if lock.withLock({ enabled }) { throw NSError(domain: NSCocoaErrorDomain, code: 640) }
  }
}

@Test func swiftDataSaveFailureRollsBackAndCanRetryWithoutDeletingHistory() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let fault = SaveFailureSwitch()
  let store = try await ConversationStore.open(root: root) { context in
    try fault.check()
    try context.save()
  }
  let cid = try await store.create(modelPath: "/fixture")
  let pending = try await store.begin(
    conversationID: cid, prompt: "保存故障", modelPath: "/fixture", sampling: Sampling())
  try await store.checkpoint(
    attemptID: pending.attemptID, instanceID: nil, text: "已经保存", status: "streaming", sequence: 1,
    usage: nil, errorCode: nil)
  fault.set(true)
  await #expect(throws: StorageFailure.self) {
    try await store.checkpoint(
      attemptID: pending.attemptID, instanceID: nil, text: "已经保存＋新内容👩‍💻", status: "stop", sequence: 2,
      usage: nil, errorCode: nil)
  }
  var snapshot = try await store.testSnapshots().first?.attempts.first
  #expect(snapshot?.reply == "已经保存")
  #expect(snapshot?.status == "streaming")
  #expect(snapshot?.lastSequence == 1)
  fault.set(false)
  try await store.checkpoint(
    attemptID: pending.attemptID, instanceID: nil, text: "已经保存＋新内容👩‍💻", status: "stop", sequence: 2,
    usage: nil, errorCode: nil)
  snapshot = try await store.testSnapshots().first?.attempts.first
  #expect(snapshot?.reply == "已经保存＋新内容👩‍💻")
  #expect(snapshot?.status == "stop")
  #expect(try await store.testSnapshots().first?.selectedLeafID == pending.attemptID)
}

@Test func ownedWorkerDrainsUnterminatedOutputAndExitsOnControlEOF() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = root.appendingPathComponent("输出夹具.sh")
  try Data(
    "#!/bin/sh\n/usr/bin/head -c 8388608 /dev/zero >&2\n/usr/bin/head -c 8388608 /dev/zero\n/bin/cat >/dev/null\n"
      .utf8
  ).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  let worker = try Worker(executable: executable, root: root)
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while worker.outputSnapshot.stdoutBytes < 8_388_608, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(worker.outputSnapshot.stdoutBytes == 8_388_608)
  #expect(worker.outputSnapshot.stderrBytes == 8_388_608)
  #expect(worker.isRunning)
  worker.requestStop()
  #expect(await worker.wait(seconds: 5))
  #expect(worker.process.terminationStatus == 0)
}

@Test func incompatibleLiveOwnerIsNeverReplaced() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let lock = try files.lock()
  var identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: files.rootIdentity, ownership: .foreground)
  identity.buildID = "previous-build"
  try files.publish(
    .init(identity: identity, privateEndpoint: "http://127.0.0.1:1", token: ServiceFiles.token()))
  do {
    _ = try await Connection.open(
      root: root.path, executable: URL(fileURLWithPath: "/nonexistent-must-not-run"))
    Issue.record("Must reject live incompatible owner")
  } catch let error as MoxError { #expect(error.code == .incompatibleService) }
  #expect(try files.read(matchingBuild: false)?.identity == identity)
  withExtendedLifetime(lock) {}
}

@Test func abandonedClientConsumerCancelsBackendAndRejectsSecondConsumer() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService(backend: ServiceBackend(count: 10000, delay: .milliseconds(2))) {
    client, runtime in
    let remote = try client.generate(path: model.directory.path, request: serviceRequest())
    let consumer = Task { for try await _ in remote.events {} }
    try await Task.sleep(for: .milliseconds(150))
    var other = remote.events.makeAsyncIterator()
    await #expect(throws: MoxError.self) { _ = try await other.next() }
    consumer.cancel()
    _ = try? await consumer.value
    let stoppedBy = ContinuousClock.now.advanced(by: .seconds(2))
    while await runtime.snapshot().activeLeases != 0, ContinuousClock.now < stoppedBy {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runtime.snapshot().activeLeases == 0)
  }
}

@Test func unconsumedClientQueueFailsAndReleasesLease() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService(backend: ServiceBackend(count: 10000, delay: .milliseconds(1))) {
    client, runtime in
    let remote = try client.generate(path: model.directory.path, request: serviceRequest())
    try await Task.sleep(for: .seconds(1))
    do {
      for try await _ in remote.events {}
      Issue.record("Unconsumed stream must fail")
    } catch let error as MoxError { #expect(error.code == .slowConsumer) }
    #expect(await runtime.snapshot().activeLeases == 0)
  }
}

@Test func nonGenerationBodiesAreRejectedWithoutDrain() async throws {
  try await withService { client, _ in
    let request = try client.request(
      "/state", method: "POST", body: Data(repeating: 32, count: 1024))
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 400)
    #expect(try await client.state().serviceState == "running")
  }
}

@Test func nonReadingSocketTimesOutAndReleasesBackend() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService(
    backend: ServiceBackend(
      count: 10000, delay: .milliseconds(1), text: String(repeating: "x", count: 16384))
  ) { client, runtime in
    let request = try serviceRequest()
    let body = try Wire.encode(GenerateBody(path: model.directory.path, request: request))
    let peer = try await Task.detached {
      let peer = try SocketPeer(client: client, receiveBufferBytes: 1024)
      try peer.send(SocketPeer.generationHead(client: client, contentLength: body.count) + body)
      return peer
    }.value
    defer { withExtendedLifetime(peer) {} }
    try await Task.sleep(for: .seconds(7))
    #expect(await runtime.snapshot().activeLeases == 0)
    #expect(try await client.requestState(request.id).terminal != nil)
    #expect(try await client.state().serviceState == "running")
  }
}

@Test func chatSaveFailurePreservesLiveReplyAndBlocksNewSendUntilRetry() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let lock = try files.lock()
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let fault = SaveFailureSwitch()
  let store = try await ConversationStore.open(root: root) { context in
    try fault.check()
    try context.save()
  }
  _ = try await store.create(modelPath: model.directory.path)
  try await withService(
    backend: ServiceBackend(count: 10000, delay: .milliseconds(2)), rootIdentity: files.rootIdentity
  ) { client, runtime in
    try files.publish(client.discovery)
    let chat = await ChatController(
      root: root.path, executable: URL(fileURLWithPath: "/must-not-launch"),
      openStore: { _ in store })
    await chat.start()
    await MainActor.run { chat.draft = "save-failure-fixture" }
    await chat.send()
    try await Task.sleep(for: .milliseconds(200))
    fault.set(true)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await chat.isWorking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await chat.isWorking == false)
    #expect(await chat.live?.saved == false)
    let diagnostics = String(decoding: try await chat.diagnostics(), as: UTF8.self)
    #expect(!diagnostics.contains("save-failure-fixture"))
    #expect(!diagnostics.contains(model.directory.path))
    #expect(!diagnostics.contains(client.discovery.token))
    let attemptID = await chat.live?.attemptID
    let text = await chat.live?.text
    #expect(text?.isEmpty == false)
    let originalConversation = await chat.selectedID
    fault.set(false)
    await chat.newConversation()
    #expect(await chat.selectedID != originalConversation)
    fault.set(true)
    await chat.select(originalConversation)
    let selectedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await chat.selected?.id != originalConversation, ContinuousClock.now < selectedDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await chat.live?.text == text)
    #expect(await chat.live?.saved == false)
    await MainActor.run { chat.draft = "must-not-send" }
    await chat.send()
    #expect(await chat.live?.attemptID == attemptID)
    #expect(try await store.testSnapshots().flatMap(\.attempts).count == 1)
    #expect(await runtime.snapshot().activeLeases == 0)
    #expect(await chat.shutdown() == false)
    fault.set(false)
    #expect(await chat.canDeleteSelected == false)
    await chat.deleteSelected()
    #expect(try await store.testSnapshots().flatMap(\.attempts).first?.id == attemptID)
    #expect(await chat.live?.saved == false)
    await chat.retrySave()
    #expect(await chat.live?.saved == true)
    #expect(try await store.testSnapshots().flatMap(\.attempts).first?.reply == text)
    #expect(await chat.shutdown())
  }
  withExtendedLifetime(lock) {}
}

@Test @MainActor func chatStoreOpenFailureDoesNotStartServiceOrReplaceFiles() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appendingPathComponent("existing-data")
  try Data("preserve".utf8).write(to: marker)
  let chat = ChatController(
    root: root.path, executable: URL(fileURLWithPath: "/must-not-launch"),
    openStore: { _ in throw MoxError(.storageFailed, "Injected store open failure") })
  await chat.start()
  #expect(chat.storageAvailable == false)
  #expect(chat.connection == nil)
  #expect(chat.error?.contains("storageFailed") == true)
  #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve")
}

@Test func forcedWorkerExitEscalatesOnlyTheOwnedProcess() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = root.appendingPathComponent("unresponsive-worker.sh")
  try Data("#!/bin/sh\ntrap '' TERM\nprintf ready\nexec /bin/sleep 60\n".utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  let other = Process()
  other.executableURL = URL(fileURLWithPath: "/bin/sleep")
  other.arguments = ["60"]
  try other.run()
  defer {
    if other.isRunning {
      other.terminate()
      other.waitUntilExit()
    }
  }
  let worker = try Worker(executable: executable, root: root)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while worker.outputSnapshot.stdoutBytes < 5, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(worker.outputSnapshot.stdoutBytes == 5)
  await worker.forceStop()
  #expect(!worker.isRunning)
  #expect(worker.process.terminationReason == .uncaughtSignal)
  #expect(worker.process.terminationStatus == SIGKILL)
  #expect(other.isRunning)
}

@Test func concurrentSwiftDataConstructionKeepsStoresIsolated() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<16 {
      group.addTask {
        let store = try await ConversationStore.open(
          root: root.appendingPathComponent("store-\(index)"))
        _ = try await store.create(modelPath: "model-\(index)")
        let list = try await store.testSnapshots()
        #expect(list.count == 1)
        #expect(list.first?.modelPath == "model-\(index)")
      }
    }
    try await group.waitForAll()
  }
}

@Test func cancellingRejectedDuplicateDoesNotCancelAcceptedRequest() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService { client, _ in
    let request = try serviceRequest()
    let accepted = try client.generate(path: model.directory.path, request: request)
    var checked = false
    var reason: FinishReason?
    for try await event in accepted.events {
      if !checked {
        checked = true
        let duplicate = try client.generate(path: model.directory.path, request: request)
        await #expect(throws: MoxError.self) { for try await _ in duplicate.events {} }
        #expect(duplicate.wasRejected)
        duplicate.cancel()
        #expect(await duplicate.waitUntilStopped())
      }
      if case .finished(let value) = event.payload { reason = value }
    }
    #expect(checked)
    #expect(reason == .stop)
    #expect(!accepted.wasRejected)
  }
}

@Test func privateEarlyRejectionsCloseUnreadBodies() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let manager = DownloadManager(persistence: store, artifacts: try ArtifactStore(root: root))
  try await withService(downloads: manager, sources: CredentialProbe()) { client, _ in
    let cases = [
      ("/mox/v1/downloads", "Content-Length: 16385", " 413 "),
      ("/mox/v1/models/\(UUID())/sampling", "Transfer-Encoding: chunked", " 404 "),
      ("/mox/v1/models/\(UUID())/pin", "Transfer-Encoding: chunked", " 404 "),
      ("/mox/v1/unknown", "Transfer-Encoding: chunked", " 400 "),
    ]
    for (path, framing, status) in cases {
      try await Task.detached {
        let peer = try SocketPeer(client: client)
        try peer.send(
          Data(
            "POST \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(client.discovery.token)\r\n\(framing)\r\n\r\n"
              .utf8))
        let response = try peer.receiveHead()
        #expect(response.contains(status))
        #expect(response.lowercased().contains("connection: close"))
        var bytes = [UInt8](repeating: 0, count: 4096)
        var count: Int
        repeat { count = recv(peer.fd, &bytes, bytes.count, 0) } while count > 0
        #expect(count == 0)
      }.value
    }
  }
}

@Test func managementWorkDeadlineIncludesSourceResolutionAndModelLoad() throws {
  let identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: "fixture", ownership: .foreground)
  let client = ServiceClient(
    discovery: .init(
      identity: identity, privateEndpoint: "http://127.0.0.1:12345", token: "fixture"))
  #expect(
    try client.request("/downloads", method: "POST").timeoutInterval
      == ServiceTiming.managementWorkTimeout)
  #expect(
    try client.request("/downloads/plan", method: "POST").timeoutInterval
      == ServiceTiming.managementWorkTimeout)
  #expect(
    try client.request("/models/\(UUID())/load", method: "POST").timeoutInterval
      == ServiceTiming.managementWorkTimeout)
  #expect(try client.request("/state").timeoutInterval == ServiceTiming.requestTimeout)
}
