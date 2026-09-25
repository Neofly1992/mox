import MoxDomain

/// Uses the official tokenizer for decoding, but computes deltas in Unicode scalars:
/// a later combining mark can extend an already emitted grapheme. Retained token IDs
/// are bounded by the generation's maxTokens. Incomplete byte sequences wait until
/// the next token; final decoding preserves any remaining replacement characters.
struct ScalarStreamingDecoder {
  let decode: ([Int]) -> String
  private var tokens: [Int] = []
  private var emitted: [Unicode.Scalar] = []
  private let batchSize: Int
  private var buffered = 0
  private var lastDecode = ContinuousClock.now

  init(batchSize: Int = 1, decode: @escaping ([Int]) -> String) {
    self.batchSize = max(1, batchSize); self.decode = decode
  }

  mutating func append(_ token: Int) throws -> String {
    tokens.append(token)
    buffered += 1
    // First content stays immediate. Fast token callbacks coalesce prefix work;
    // slower models flush on the first callback after 50 ms, without a timer/task.
    guard tokens.count == 1 || buffered >= batchSize || lastDecode.duration(to: .now) >= .milliseconds(50) else { return "" }
    return try delta(final: false)
  }

  mutating func finish() throws -> String { try delta(final: true) }

  private mutating func delta(final: Bool) throws -> String {
    buffered = 0; lastDecode = .now
    var scalars = Array(decode(tokens).unicodeScalars)
    if !final {
      while scalars.last == "\u{fffd}" { scalars.removeLast() }
    }
    guard scalars.starts(with: emitted) else {
      throw MoxError(.generationFailed, "Tokenizer revised already emitted text; generation cannot continue losslessly.")
    }
    let text = String(String.UnicodeScalarView(scalars.dropFirst(emitted.count)))
    emitted = scalars
    return text
  }
}
