import Foundation
import MoxDomain
import Testing
@testable import MoxCore

@Test func outputLifetimeLimitIsIndependentOfPendingBuffer() async {
  let handle = GenerationHandle(requestID: UUID(), capacity: 100, byteLimit: 32 * 1024 * 1024)
  let part = String(repeating: "x", count: 1024 * 1024)
  for _ in 0..<16 { #expect(handle.emit(.contentDelta(part))) }
  #expect(!handle.emit(.contentDelta("x")))
  handle.finish(.finished(.stop))
  var failure: MoxError?
  for await event in handle.events { if case .failed(let error) = event.payload { failure = error } }
  #expect(failure?.code == .resourceLimit)
}
@Test func toolOutputCountAndArgumentBoundsHaveStableTerminalFailure() async {
  for oversized in [false, true] {
    let handle = GenerationHandle(requestID: UUID())
    if oversized {
      #expect(!handle.emit(.toolCall(id: "call", name: "fixture", arguments: String(repeating: "x", count: 65537))))
    } else {
      for index in 0..<32 { #expect(handle.emit(.toolCall(id: "call-\(index)", name: "fixture", arguments: "{}"))) }
      #expect(!handle.emit(.toolCall(id: "extra", name: "fixture", arguments: "{}")))
    }
    handle.finish(.finished(.toolCalls))
    var failure: MoxError?
    for await event in handle.events { if case .failed(let error) = event.payload { failure = error } }
    #expect(failure?.code == .resourceLimit)
  }
}
