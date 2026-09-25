import Foundation
import Hummingbird
import MoxDomain
import MoxProtocol
import Testing

@testable import MoxClient

private func wireServer(
  parts: [Data], fragmentSize: Int = 1,
  _ test: (ServiceClient, GenerationRequest) async throws -> Void
) async throws {
  let identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: "wire", ownership: .foreground)
  let request = try serviceRequest()
  let router = Router()
  router.post("/mox/v1/generations") { _, _ in
    Response(
      status: .ok,
      headers: [
        .contentType: "text/event-stream", .init("X-Mox-Instance")!: identity.instanceID.uuidString,
      ],
      body: .init { writer in
        for part in parts {
          // Replace only the known fixture IDs, then fragment at byte boundaries.
          var bytes = part
          for (marker, replacement) in [
            ("INSTANCE", identity.instanceID.uuidString), ("REQUEST", request.id.uuidString),
          ] {
            while let range = bytes.range(of: Data(marker.utf8)) {
              bytes.replaceSubrange(range, with: replacement.utf8)
            }
          }
          for start in stride(from: 0, to: bytes.count, by: fragmentSize) {
            try await writer.write(
              ByteBuffer(bytes: bytes[start..<min(start + fragmentSize, bytes.count)]))
          }
        }
        try await writer.finish(nil)
      })
  }
  let ready = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let application = Application(
    router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
    onServerRunning: { channel in
      if let port = channel.localAddress?.port { ready.continuation.yield(port) }
    })
  let task = Task { try await application.run() }
  var ports = ready.stream.makeAsyncIterator()
  let port = await ports.next()!
  let client = ServiceClient(
    discovery: Discovery(
      identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: "fixture"))
  do { try await test(client, request) } catch {
    task.cancel()
    _ = try? await task.value
    throw error
  }
  task.cancel()
  _ = try? await task.value
}
private func frame(_ sequence: Int, _ fields: String) -> Data {
  Data(
    "event: generation\r\nid: \(sequence)\r\ndata: {\"instanceID\":\"INSTANCE\",\"requestID\":\"REQUEST\",\"sequence\":\(sequence),\(fields)}\r\n\r\n"
      .utf8)
}
@Test func fragmentedUTF8AndCRLFAreLossless() async throws {
  try await wireServer(parts: [
    frame(0, #""type":"contentDelta","text":"中é👩‍💻""#),
    frame(1, #""type":"finished","reason":"stop""#),
  ]) { client, request in
    let stream = try client.generate(path: "/fixture", request: request)
    var text = ""
    for try await event in stream.events {
      if case .contentDelta(let delta) = event.payload { text += delta }
    }
    #expect(text == "中é👩‍💻")
  }
}
@Test func missingTerminalAndLateEventsFail() async throws {
  let content = frame(0, #""type":"contentDelta","text":"partial""#)
  for frames in [
    [content],
    [
      frame(0, #""type":"finished","reason":"stop""#),
      frame(1, #""type":"contentDelta","text":"late""#),
    ], [frame(1, #""type":"finished","reason":"stop""#)],
  ] {
    try await wireServer(parts: frames) { client, request in
      let stream = try client.generate(path: "/fixture", request: request)
      await #expect(throws: (any Error).self) { for try await _ in stream.events {} }
    }
  }
}

@Test func emptyReplyIsValidButInvalidUTF8AndUnterminatedOversizeLineFail() async throws {
  try await wireServer(parts: [frame(0, #""type":"finished","reason":"stop""#)]) {
    client, request in
    let remote = try client.generate(path: "/fixture", request: request)
    var count = 0
    for try await event in remote.events {
      #expect(event.payload.isTerminal)
      count += 1
    }
    #expect(count == 1)
  }
  for bytes in [Data([0xff, 10, 10]), Data(repeating: 120, count: Wire.frameLimit + 1)] {
    try await wireServer(parts: [bytes], fragmentSize: 4096) { client, request in
      let remote = try client.generate(path: "/fixture", request: request)
      do {
        for try await _ in remote.events {}
        Issue.record("Invalid byte stream succeeded")
      } catch let error as MoxError { #expect(error.code == .protocolViolation) }
    }
  }
}

private actor RedirectCounter {
  var hits = 0
  func record() { hits += 1 }
}
@Test func redirectsNeverForwardManagementCredentials() async throws {
  let identity = ServiceIdentity(
    pid: getpid(), uid: getuid(), rootIdentity: "redirect", ownership: .foreground)
  let counter = RedirectCounter()
  let router = Router()
  router.get("/mox/v1/identity") { _, _ in
    Response(
      status: .temporaryRedirect,
      headers: [
        .location: "/credential-target", .init("X-Mox-Instance")!: identity.instanceID.uuidString,
      ])
  }
  router.get("/credential-target") { _, _ in
    await counter.record()
    return Response(status: .ok)
  }
  let ready = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let application = Application(
    router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
    onServerRunning: { channel in ready.continuation.yield(channel.localAddress!.port!) })
  let server = Task { try await application.run() }
  var ports = ready.stream.makeAsyncIterator()
  let port = await ports.next()!
  let client = ServiceClient(
    discovery: .init(
      identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: "credential-sentinel")
  )
  do {
    _ = try await client.identity()
    Issue.record("Redirect accepted")
  } catch let error as MoxError { #expect(error.code == .protocolViolation) }
  #expect(await counter.hits == 0)
  server.cancel()
  _ = try? await server.value
}

@Test func jsonCancellationBeforeRegistrationCompletesWithoutStartingTransfer() async throws {
  let transfer = BoundedTransfer(instance: UUID(), requestID: nil)
  let request = URLRequest(url: URL(string: "http://127.0.0.1:1/never-start")!)
  // A completion before registration is the critical interleaving of early cancellation.
  let task = URLSession.shared.dataTask(with: request)
  transfer.urlSession(URLSession.shared, task: task, didCompleteWithError: CancellationError())
  do {
    _ = try await transfer.collect(request: request)
    Issue.record("Cancelled transfer resumed successfully")
  } catch let error as MoxError {
    #expect(error.code == .connectionLost)
  }
}
