@testable import MoxMLX
import MoxDomain
import Testing

@Test func stopSequenceCrossesUnicodeChunksWithoutLeaking() {
  var filter = StopSequenceFilter(["👨‍👩‍👧‍👦END"])
  var visible = ""
  for piece in ["hello👨", "‍👩‍", "👧‍👦EN", "Dhidden"] { visible += filter.accept(piece) }
  visible += filter.finish()
  #expect(visible == "hello")
  #expect(filter.matched == "👨‍👩‍👧‍👦END")
}

@Test func modelHistoryKeepsMixedTextCallsAndResultsInOrder() throws {
  let history: [MoxDomain.Message] = [
    .init(role: .assistant, content: [.text("before"),
      .toolCall(id: "call_1", name: "lookup_code", arguments: "{\"code\":\"MOX-7\"}"),
      .text("after")]),
    .init(role: .user, content: [.text("context"),
      .toolResult(callID: "call_1", text: "unknown code", isError: true),
      .text("recover")]),
  ]
  let mapped = try MLXLoadedModel.chatMessages(history)
  #expect(mapped.map { $0.role.rawValue } == ["assistant", "assistant", "assistant", "user", "tool", "user"])
  #expect(mapped.map(\.content) == ["before", "", "after", "context", "Error: unknown code", "recover"])
}

@Test func stopSequenceFlushesUnmatchedPrefix() {
  var filter = StopSequenceFilter(["STOP"])
  #expect(filter.accept("helloST") == "hello")
  #expect(filter.finish() == "ST")
  #expect(filter.matched == nil)
}
