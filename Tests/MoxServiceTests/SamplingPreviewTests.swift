import Foundation
import Hummingbird
import MoxBootstrap
import MoxChat
import MoxClient
import MoxDomain
import MoxProtocol
import Testing

/// Delay an already resolved response, so tests exercise late HTTP results rather
/// than reproducing sampling precedence in a test double.
private actor SamplingResponseGate {
  var armed = false
  var waiting = false
  private var continuation: CheckedContinuation<Void, Never>?
  func arm() { armed = true }
  func waitIfArmed() async -> Bool {
    guard armed else { return false }
    armed = false
    waiting = true
    await withCheckedContinuation { continuation = $0 }
    waiting = false
    return true
  }
  func release() { continuation?.resume(); continuation = nil }
}

@Test(arguments: ["edit", "model", "defaults", "reconnect", "failure"])
func samplingPreviewDiscardsLateResponse(change: String) async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let ownership = try files.lock()
  let gate = SamplingResponseGate()
  try await withService(rootIdentity: files.rootIdentity, launchSampling: .init(maxTokens: 71)) {
    base, _ in
    let identity = base.discovery.identity
    let headers: HTTPFields = [.contentType: "application/json",
      .init("X-Mox-Instance")!: identity.instanceID.uuidString]
    let router = Router()
    router.get("/mox/v1/identity") { _, _ in
      Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: try Wire.encode(identity))))
    }
    router.get("/mox/v1/state") { _, _ in
      Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: try await Wire.encode(base.state()))))
    }
    router.post("/mox/v1/config/effective") { request, _ in
      var bytes = Data()
      for try await buffer in request.body { bytes.append(contentsOf: buffer.readableBytesView) }
      let body = try Wire.decode(SamplingResolutionBody.self, bytes)
      let effective = try await base.resolveSampling(body)
      let delayed = await gate.waitIfArmed()
      if delayed, change == "failure" {
        return Response(status: .badRequest, headers: headers,
          body: .init(byteBuffer: ByteBuffer(bytes: try Wire.encode(ErrorEnvelope(
            instanceID: identity.instanceID, error: MoxError(.invalidParameters, "Injected late failure"))))))
      }
      return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: try Wire.encode(effective))))
    }
    let ready = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
      onServerRunning: { channel in ready.continuation.yield(channel.localAddress!.port!) })
    let server = Task { try await app.run() }
    var ports = ready.stream.makeAsyncIterator()
    let port = try #require(await ports.next())
    try files.publish(.init(identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: base.discovery.token))
    let chat = await ChatController(root: root.path, executable: URL(fileURLWithPath: "/never-launch"))
    await chat.start()
    await chat.selectModel(path: "/fixture/first")
    await chat.setMaxTokensOverride(41)
    await chat.refreshEffectiveSampling()
    await gate.arm()
    let old = Task { await chat.refreshEffectiveSampling() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await gate.waiting), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await gate.waiting)
    switch change {
    case "edit", "failure":
      await chat.setMaxTokensOverride(42)
      await chat.setTemperatureOverride(0.4)
      await chat.refreshEffectiveSampling()
    case "model": await chat.selectModel(path: "/fixture/second")
    case "defaults": await chat.restoreSamplingDefaults()
    default: await chat.connect()
    }
    let latest = await chat.effectiveSampling
    await gate.release()
    await old.value
    #expect(await chat.effectiveSampling == latest)
    #expect(await chat.samplingPreviewError == nil)
    #expect(await chat.effectiveSampling?.maxTokens == ((change == "edit" || change == "failure") ? 42 : change == "reconnect" ? 41 : 71))
    #expect(await chat.effectiveSampling?.maxTokensSource == (change == "edit" || change == "failure" || change == "reconnect" ? .request : .launch))
    #expect(await chat.shutdown())
    server.cancel()
    _ = try? await server.value
  }
  withExtendedLifetime(ownership) {}
}
