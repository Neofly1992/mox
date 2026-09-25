import Foundation

/// Presentation chunks are produced off MainActor. App views only lay out changed tails.
public struct TextSegments: Sendable {
  public private(set) var values: [String] = []
  private var tailCount = 0
  public init(_ text: String = "") { append(text) }
  public mutating func append(_ text: String) {
    for scalar in text.unicodeScalars {
      if values.isEmpty || tailCount >= ChatPolicy.segmentScalars {
        values.append("")
        tailCount = 0
      }
      values[values.count - 1].unicodeScalars.append(scalar)
      tailCount += 1
    }
  }
}
