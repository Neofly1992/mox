import MoxDomain
import Testing
@testable import MoxMLX

@Test func streamingPreservesScalarBoundaries() throws {
  for pieces in [["a", "\u{301}"], ["👩", "\u{200d}", "💻"], ["🇨", "🇳"], ["hello", "\n", "世界"]] {
    var decoder = ScalarStreamingDecoder { ids in ids.map { pieces[$0] }.joined() }
    var result = ""
    for index in pieces.indices { result += try decoder.append(index) }
    result += try decoder.finish()
    #expect(Array(result.unicodeScalars) == Array(pieces.joined().unicodeScalars))
  }
}

@Test func streamingWaitsForBytesAndFlushesFinalTail() throws {
  var decoder = ScalarStreamingDecoder { $0.count == 1 ? "x�" : "x中" }
  #expect(try decoder.append(1) == "x")
  #expect(try decoder.append(2) == "中")
  #expect(try decoder.finish() == "")
  var truncated = ScalarStreamingDecoder { _ in "x�" }
  #expect(try truncated.append(1) == "x")
  #expect(try truncated.finish() == "�")
}

@Test func streamingRejectsRevisedPrefix() throws {
  var decoder = ScalarStreamingDecoder { $0.count == 1 ? "a" : "b" }
  #expect(try decoder.append(1) == "a")
  #expect(throws: MoxError.self) { try decoder.append(2) }
}

@Test func batchedStreamingKeepsFirstContentAndFlushesUnicodeTail() throws {
  let pieces = ["a", "\u{301}", "👩", "\u{200d}", "💻", "\n", "中"]
  var decoder = ScalarStreamingDecoder(batchSize: 8) { ids in ids.map { pieces[$0] }.joined() }
  var result = try decoder.append(0)
  #expect(result == "a")
  for index in 1..<pieces.count { result += try decoder.append(index) }
  result += try decoder.finish()
  #expect(Array(result.unicodeScalars) == Array(pieces.joined().unicodeScalars))
}
