/// Shared bounds for each generation consumer, plus one reserved terminal slot.
public enum StreamLimits {
  public static let maximumOutputBytes = 16 * 1024 * 1024
  public static let maximumToolCalls = 32
  public static let maximumToolArgumentBytes = 64 * 1024
  public static let pendingEvents = 128
  public static let pendingTextBytes = 256 * 1024
}
