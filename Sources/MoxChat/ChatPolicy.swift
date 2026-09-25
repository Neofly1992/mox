import Foundation

/// Presentation and disk checkpoint cadence are independent of GPU cancellation.
enum ChatPolicy {
  static let refresh: Duration = .milliseconds(50)
  static let checkpointInterval: Duration = .milliseconds(250)
  static let checkpointBytes = 8 * 1024
  static let saveBarrierPoll: Duration = .milliseconds(10)
  static let servicePoll: Duration = .seconds(2)
  static let longStopNotice: Duration = .seconds(10)
  static let reconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .milliseconds(7500),
  ]
  static let segmentScalars = 2048
}
