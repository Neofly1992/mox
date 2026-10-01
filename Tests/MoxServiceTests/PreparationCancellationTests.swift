import Darwin
import Foundation
import MoxDomain
import MoxPersistence
import MoxProtocol
import Testing

@testable import MoxCore

private actor GenerationEntries {
  var ids = Set<UUID>()
  func record(_ id: UUID) { ids.insert(id) }
}
private actor ReviewPendingVerifier: CommittedArtifactVerifying {
  var entered = false
  var calls = 0
  func inspect(_ origin: ArtifactOrigin, in store: ArtifactStore) async throws -> ArtifactManifest {
    entered = true
    calls += 1
    try await Task.sleep(for: .seconds(17))
    return try store.inspectCommitted(origin)
  }
}
@Test(arguments: [false, true])
func reviewVerificationRequestMustBeVisibleAndCancellable(resetConnection: Bool) async throws {
  let root = try temporaryRoot()
  let model = try serviceModel()
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let store = try await RuntimeStore.open(root: root)
  let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
  let item = try committedServiceInstallation(
    model: model,
    origin: .init(
      registryID: UUID(), repository: "fixture/pending", revision: String(repeating: "a", count: 40)
    ), artifacts: artifacts)
  try await store.commit(.init(installations: [item]))
  let verifier = ReviewPendingVerifier()
  let manager = DownloadManager(persistence: store, artifacts: artifacts, verifier: verifier)
  let entries = GenerationEntries()
  try await withService(
    backend: ServiceBackend(onGenerate: { id in await entries.record(id) }), downloads: manager
  ) { client, runtime in
    let request = try serviceRequest()
    let remote = try client.generate(
      model: .init(kind: "installedAlias", path: item.alias), request: request)
    let consumer = Task {
      var last: GenerationPayload?
      for try await event in remote.events { last = event.payload }
      return last
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await verifier.entered), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await verifier.entered)
    let state = try await client.state()
    #expect(state.requests.contains { $0.requestID == request.id })
    let survivor = try client.generate(
      model: .init(kind: "installedAlias", path: item.alias), request: serviceRequest())
    let survivorConsumer = Task {
      var last: GenerationPayload?
      for try await event in survivor.events { last = event.payload }
      return last
    }
    let disconnectedRequest = try serviceRequest()
    var disconnectedBody = try GenerateBody(path: item.path, request: disconnectedRequest)
    disconnectedBody.model = .init(kind: "installedAlias", path: item.alias)
    let bytes = try Wire.encode(disconnectedBody)
    try await Task.detached {
      let peer = try SocketPeer(client: client)
      try peer.send(SocketPeer.generationHead(client: client, contentLength: bytes.count) + bytes)
      #expect(try peer.receiveHead().contains("200"))
      if resetConnection {
        var reset = linger(l_onoff: 1, l_linger: 0)
        setsockopt(peer.fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
      } else {
        shutdown(peer.fd, SHUT_RDWR)
      }
    }.value
    // HTTP permits remote half-close. A FIN can require heartbeat write and
    // write-failure detection; an RST closes immediately. No production deadline changes.
    let disconnectWindow: Duration =
      resetConnection
      ? .seconds(2) : ServiceTiming.heartbeat + ServiceTiming.writeDeadline + .seconds(2)
    let disconnectStarted = ContinuousClock.now
    let disconnectedBy = disconnectStarted.advanced(by: disconnectWindow)
    var disconnectedTerminal = false
    while ContinuousClock.now < disconnectedBy {
      if !(try await client.state().requests.contains { $0.requestID == disconnectedRequest.id }) {
        disconnectedTerminal = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(disconnectedTerminal, "Transport closure must cancel the verification waiter")
    if disconnectedTerminal {
      let terminal = try #require(try await client.cancel(disconnectedRequest.id).terminal)
      if case .finished(.cancelled) = try terminal.event().payload {
      } else {
        Issue.record("Disconnected preparation must terminate as cancelled")
      }
      print(
        "PREPARATION disconnect=\(resetConnection ? "RST" : "FIN") elapsed=\(ContinuousClock.now - disconnectStarted)"
      )
    }
    var cancellationError: String?
    do { _ = try await client.cancel(request.id) } catch {
      cancellationError = (error as? MoxError)?.code.rawValue ?? "other"
    }
    #expect(cancellationError == nil)
    let cancelledBy = ContinuousClock.now.advanced(by: .seconds(2))
    var terminal = false
    while ContinuousClock.now < cancelledBy {
      if !(try await client.state().requests.contains { $0.requestID == request.id }) {
        terminal = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(terminal, "Cancellation must stop this waiter before the 17-second verifier finishes")
    #expect(await runtime.snapshot().activeLeases == 0)
    if !terminal { await manager.shutdown() }
    if case .finished(.cancelled) = try await consumer.value {
    } else {
      Issue.record("Expected cancelled terminal during verification")
    }
    // The other caller has remained connected through a 17-second verification,
    // exceeding the client's 15-second idle deadline and requiring SSE heartbeats.
    let last = try await survivorConsumer.value
    if case .finished(.stop) = last {
    } else {
      Issue.record("Shared verification did not survive cancellation")
    }
    #expect(await verifier.calls == 1)
    #expect(await entries.ids == [survivor.requestID])
    let next = try client.generate(
      model: .init(kind: "installedAlias", path: item.alias), request: serviceRequest())
    for try await _ in next.events {}
    #expect(await entries.ids == [survivor.requestID, next.requestID])
    #expect(await verifier.calls == 1)
    await manager.shutdown()
  }
}
