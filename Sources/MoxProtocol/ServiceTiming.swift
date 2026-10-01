import Foundation

/// Local control-plane deadlines. Heartbeats must arrive before the request idle timeout.
public enum ServiceTiming {
  public static let maximumStreamLifetime: TimeInterval = 24 * 60 * 60
  public static let managementWorkTimeout: TimeInterval = 15 * 60
  public static let requestTimeout: TimeInterval = 15
  public static let cancellationRequestTimeout: TimeInterval = 2
  public static let shutdownSeconds: Double = 30
  public static let readiness: Duration = .seconds(15)
  public static let controlPoll: Duration = .milliseconds(50)
  public static let stoppedPoll: Duration = .milliseconds(100)
  public static let heartbeat: Duration = .seconds(5)
  public static let writeDeadline: Duration = .seconds(5)
  public static let terminationSeconds: Double = 5
  public static let registrationCancelAttempts = 300
}
