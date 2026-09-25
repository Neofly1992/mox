import Foundation

/// Numeric, bounded diagnostics; no prompt, path, or arbitrary event labels.
public final class PerformanceMetrics: @unchecked Sendable {
  public enum Metric: String, CaseIterable, Sendable {
    case checkpoint, mainRunLoop, stopPresentation
  }
  public struct Summary: Codable, Sendable {
    public var count = 0
    public var maximumMilliseconds = 0.0
    public var totalMilliseconds = 0.0
    public var histogram = [Int](repeating: 0, count: 1002)
    public var p95UpperBoundMilliseconds: Int {
      let target = Int(ceil(Double(count) * 0.95))
      var accumulated = 0
      for (index, value) in histogram.enumerated() {
        accumulated += value
        if accumulated >= target { return index }
      }
      return 1001
    }
  }
  private let lock = NSLock()
  private var values: [String: Summary] = [:]
  public init() {}
  public func record(_ metric: Metric, seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    var value = values[metric.rawValue, default: Summary()]
    let milliseconds = seconds * 1000
    value.count += 1
    value.totalMilliseconds += milliseconds
    value.maximumMilliseconds = max(value.maximumMilliseconds, milliseconds)
    value.histogram[min(1001, Int(ceil(milliseconds)))] += 1
    values[metric.rawValue] = value
  }
  public func snapshot() -> [String: Summary] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
