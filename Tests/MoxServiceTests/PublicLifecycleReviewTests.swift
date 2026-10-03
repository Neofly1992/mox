import Darwin
import Foundation
import MoxBootstrap
import MoxClient
import MoxDomain
import MoxPersistence
import MoxProtocol
import MoxServer
import Security
import Testing
@testable import MoxCore

private actor PublicGenerationGate {
  var entered = false
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() { released = true; waiter?.resume(); waiter = nil }
}

@Test func publicRotationDuringStoppingIsAtomicAndResetConnectionReleasesWork() async throws {
  let root = try temporaryRoot()
  let model = try serviceModel()
  let identity = UUID().uuidString
  defer {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.mox.public-api",
      kSecAttrAccount as String: "dev.mox.public-api.\(identity)"] as CFDictionary)
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let store = try await RuntimeStore.open(root: root)
  let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
  let installation = try committedServiceInstallation(model: model,
    origin: .init(registryID: UUID(), repository: "fixture/public",
      revision: String(repeating: "a", count: 40)), artifacts: artifacts)
  try await store.commit(.init(installations: [installation]))
  let downloads = DownloadManager(persistence: store, artifacts: artifacts)
  let gate = PublicGenerationGate()
  let runtime = RuntimeCoordinator(backend: ServiceBackend(count: 1000,
    onGenerate: { _ in await gate.wait() }), policy: .init(budgetBytes: 512 * 1024 * 1024))
  let service = InferenceService(identity: .init(pid: getpid(), uid: getuid(),
    rootIdentity: identity, ownership: .foreground), token: try ServiceFiles.token(),
    runtime: runtime, downloads: downloads)
  let manager = PublicAPIManager(service: service, downloads: downloads, rootIdentity: identity)
  await service.attachPublicAPI(manager)
  _ = try await manager.setEnabled(true)
  let old = try #require(try await manager.currentKey())
  let handle = try await service.beginPublic(model: installation.alias, request: serviceRequest())
  let observing = Task {
    for await event in handle.events { await service.observePublic(event) }
  }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !(await gate.entered), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(await gate.entered)
  let disabling = Task { try await manager.setEnabled(false) }
  while !handle.isCancelled, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(handle.isCancelled)
  let rotated = try await manager.rotateKey()
  #expect(await manager.authorize(old.key) == false)
  #expect(await manager.authorize(rotated.key))
  #expect(try await manager.currentKey()?.credentialID == rotated.credentialID)
  await gate.release()
  _ = try await disabling.value
  await observing.value
  #expect(await manager.authorize(rotated.key) == false)
  let enabled = try await manager.setEnabled(true)
  #expect(enabled.credentialID == rotated.credentialID)
  #expect(await manager.authorize(rotated.key))
  let endpoint = try #require(enabled.endpoint)
  let client = ServiceClient(discovery: .init(identity: await service.identity,
    privateEndpoint: endpoint, token: rotated.key))
  let body = try JSONSerialization.data(withJSONObject: ["model": installation.alias,
    "messages": [["role": "user", "content": "fixture"]], "stream": true])
  try await Task.detached {
    let peer = try SocketPeer(client: client)
    try peer.send(Data("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(rotated.key)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
    #expect(try peer.receiveHead().contains(" 200 "))
    var reset = linger(l_onoff: 1, l_linger: 0)
    setsockopt(peer.fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
  }.value
  let stoppedBy = ContinuousClock.now.advanced(by: .seconds(5))
  while !(try await service.snapshot().requests.isEmpty), ContinuousClock.now < stoppedBy {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await service.snapshot().requests.isEmpty)
  #expect(await runtime.snapshot().activeLeases == 0)
  await service.shutdown()
}
