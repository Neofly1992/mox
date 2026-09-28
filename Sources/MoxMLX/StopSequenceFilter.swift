/// Retains a possible scalar prefix across tokenizer chunks. Grapheme boundaries can
/// change when a new chunk arrives, so Character-based suffix matching is unsafe.
struct StopSequenceFilter {
  private let sequences: [(text: String, scalars: [Unicode.Scalar])]
  private var pending: [Unicode.Scalar] = []
  private(set) var matched: String?

  init(_ sequences: [String]) {
    self.sequences = sequences.map { ($0, Array($0.unicodeScalars)) }
  }

  mutating func accept(_ text: String) -> String {
    guard matched == nil else { return "" }
    guard !sequences.isEmpty else { return text }
    pending.append(contentsOf: text.unicodeScalars)
    for start in pending.indices {
      if let hit = sequences.first(where: { entry in
        start + entry.scalars.count <= pending.count &&
          pending[start..<(start + entry.scalars.count)].elementsEqual(entry.scalars)
      }) {
        let visible = Self.string(pending[..<start])
        pending.removeAll()
        matched = hit.text
        return visible
      }
    }
    let retained = sequences.reduce(0) { largest, entry in
      let maximum = min(pending.count, entry.scalars.count - 1)
      guard maximum > largest else { return largest }
      for count in stride(from: maximum, through: largest + 1, by: -1) {
        if pending.suffix(count).elementsEqual(entry.scalars.prefix(count)) { return count }
      }
      return largest
    }
    let visible = Self.string(pending.dropLast(retained))
    pending = Array(pending.suffix(retained))
    return visible
  }

  mutating func finish() -> String {
    guard matched == nil else { return "" }
    defer { pending.removeAll() }
    return Self.string(pending[...])
  }

  private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    var result = ""
    for scalar in scalars { result.unicodeScalars.append(scalar) }
    return result
  }
}
