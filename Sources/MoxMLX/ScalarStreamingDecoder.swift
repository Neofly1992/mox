import MoxDomain

/// Uses the official tokenizer for decoding, but computes deltas in Unicode scalars:
/// a later combining mark can extend an already emitted grapheme. Retained token IDs
/// are bounded by the generation's maxTokens. Incomplete byte sequences wait until
/// the next token; final decoding preserves any remaining replacement characters.
struct ScalarStreamingDecoder {
  let decode: ([Int]) -> String
  private var tokens: [Int] = []
  private var emitted: [Unicode.Scalar] = []

  init(decode: @escaping ([Int]) -> String) { self.decode = decode }

  mutating func append(_ token: Int) throws -> String {
    tokens.append(token)
    return try delta(final: false)
  }

  mutating func finish() throws -> String { try delta(final: true) }

  private mutating func delta(final: Bool) throws -> String {
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
