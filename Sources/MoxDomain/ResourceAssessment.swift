import Foundation

public enum ResourceStatus: String, Codable, Sendable {
  case recommended, constrained, exceedsBudget, unknown
}
/// An advisory upper envelope, not a performance prediction or an OOM guarantee.
public struct ResourceAssessment: Codable, Sendable {
  public let status: ResourceStatus
  public let weightBytes: Int?
  public let loadOverheadBytes: Int?
  public let kvBytes: Int?
  public let workspaceBytes: Int?
  public let residentBytes: Int
  public let peakBytes: Int?
  public let budgetBytes: Int
  public let contextTokens: Int?
  public let maximumOutputTokens: Int?
  public let reason: String
  public let suggestion: String
  public init(
    status: ResourceStatus, weightBytes: Int? = nil, loadOverheadBytes: Int? = nil,
    kvBytes: Int? = nil, workspaceBytes: Int? = nil, residentBytes: Int = 0,
    peakBytes: Int? = nil, budgetBytes: Int, contextTokens: Int? = nil,
    maximumOutputTokens: Int? = nil,
    reason: String, suggestion: String
  ) {
    self.status = status
    self.weightBytes = weightBytes
    self.loadOverheadBytes = loadOverheadBytes
    self.kvBytes = kvBytes
    self.workspaceBytes = workspaceBytes
    self.residentBytes = residentBytes
    self.peakBytes = peakBytes
    self.budgetBytes = budgetBytes
    self.contextTokens = contextTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.reason = reason
    self.suggestion = suggestion
  }
  public static func unknown(budgetBytes: Int, reason: String) -> Self {
    .init(
      status: .unknown, budgetBytes: budgetBytes, reason: reason,
      suggestion:
        "Inspect model configuration and use a supported dense attention model; runtime admission still applies."
    )
  }
  public var summary: String {
    func bytes(_ value: Int?) -> String {
      value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
        ?? "unknown"
    }
    let additionalWeights = loadOverheadBytes.map { $0 == 0 ? 0 : weightBytes ?? 0 }
    return
      "\(status.rawValue): peak \(bytes(peakBytes)) / budget \(bytes(budgetBytes)); stored weights \(bytes(weightBytes)), additional weights \(bytes(additionalWeights)), load overhead \(bytes(loadOverheadBytes)), KV \(bytes(kvBytes)), workspace \(bytes(workspaceBytes)), existing reservations \(bytes(residentBytes)); total token envelope \(contextTokens.map(String.init) ?? "unknown"), output limit \(maximumOutputTokens.map(String.init) ?? "unknown"). \(reason) \(suggestion)"
  }
}
public enum MemoryPressureLevel: String, Codable, Sendable { case normal, warning, critical }
public struct BackendMemorySnapshot: Codable, Sendable {
  public let activeBytes: Int
  public let cacheBytes: Int
  public let peakActiveBytes: Int
  public init(activeBytes: Int, cacheBytes: Int, peakActiveBytes: Int) {
    self.activeBytes = activeBytes
    self.cacheBytes = cacheBytes
    self.peakActiveBytes = peakActiveBytes
  }
}
