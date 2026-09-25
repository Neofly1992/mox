import Foundation
import Testing
@testable import MoxMLX

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOX_BENCHMARK_OUTPUT"] != nil))
func decoderLongOutputBenchmark() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["MOX_TEST_MODEL"])
  let tokenizer = try await LocalTokenizerLoader().load(from: URL(fileURLWithPath: path))
  let all = tokenizer.encode(text: String(repeating: "Hello 世界 👩‍💻 é test. ", count: 2000), addSpecialTokens: false)
  var samples: [[String: Double]] = []
  for length in [128, 512, 2048, 8192] {
    let tokens = Array(all.prefix(length)); #expect(tokens.count == length)
    for sample in 0..<3 {
      let began = ContinuousClock.now
      let batch = Int(ProcessInfo.processInfo.environment["MOX_DECODER_BATCH"] ?? "1") ?? 1
      var decoder = ScalarStreamingDecoder(batchSize: batch) { tokenizer.decode(tokenIds: $0) }
      var output = ""
      for token in tokens { output += try decoder.append(token) }
      output += try decoder.finish()
      let elapsed = began.duration(to: .now)
      #expect(Array(output.unicodeScalars) == Array(tokenizer.decode(tokenIds: tokens).unicodeScalars))
      samples.append(["batchSize": Double(batch), "tokens": Double(length), "sample": Double(sample), "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18])
    }
  }
  let out = try #require(ProcessInfo.processInfo.environment["MOX_BENCHMARK_OUTPUT"])
  try JSONSerialization.data(withJSONObject: samples, options: .prettyPrinted).write(to: URL(fileURLWithPath: out))
  print("DECODER samples=12 Unicode=PASS")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOX_TEST_MODEL"] != nil))
func prefillCancellationFixtureExceeds4096Tokens() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["MOX_TEST_MODEL"])
  let tokenizer = try await LocalTokenizerLoader().load(from: URL(fileURLWithPath: path))
  let tokens = tokenizer.encode(text: String(repeating: "word ", count: 5000) + "Explain this at length.", addSpecialTokens: false)
  #expect(tokens.count >= 4096)
  print("PREFILL cancellation fixture inputTokens=\(tokens.count)")
}
