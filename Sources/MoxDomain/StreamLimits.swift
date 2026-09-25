/// Shared bounds for each generation consumer, plus one reserved terminal slot.
public enum StreamLimits {
  public static let pendingEvents = 128
  public static let pendingTextBytes = 256 * 1024
}
