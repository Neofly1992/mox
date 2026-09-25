import Foundation

/// Replacement pages cap resident history without deleting durable messages.
public enum HistoryLimit {
  public static let conversations = 100
  // Count and text budgets apply together; one large reply remains readable without truncation.
  public static let attempts = 8
  public static let pageTextBytes = 4 * 1024 * 1024
  public static let maximumReplyBytes = 16 * 1024 * 1024
}
public struct HistoryPage<Item: Sendable>: Sendable {
  public let items: [Item]
  public let offset: Int
  public let hasMore: Bool
  public init(items: [Item], offset: Int, hasMore: Bool) {
    self.items = items
    self.offset = offset
    self.hasMore = hasMore
  }
}
public struct ConversationSummary: Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let modelPath: String
  public let updatedAt: Date
  public let status: String
}

/// Numeric instrumentation for verifying that summary operations never decode bodies.
public struct HistoryReadMetrics: Sendable {
  public var decodedMessages = 0
  public var decodedBytes = 0
}
