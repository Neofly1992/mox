// Frozen on-disk schema, used only to migrate existing M2 conversations.
import Foundation
import MoxProtocol
import SwiftData

public enum ChatSchemaV1: VersionedSchema {
  public static let versionIdentifier = Schema.Version(1, 0, 0)
  public static var models: [any PersistentModel.Type] {
    [Conversation.self, MessageRecord.self, Attempt.self]
  }
  @Model public final class Conversation {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selectedLeafID: UUID?
    public var localModelPath: String
    public init(id: UUID, title: String, localModelPath: String) {
      self.id = id
      self.title = title
      self.localModelPath = localModelPath
      createdAt = .now
      updatedAt = .now
    }
  }
  @Model public final class MessageRecord {
    @Attribute(.unique) public var id: UUID
    public var conversationID: UUID
    public var parentID: UUID?
    public var sequence: Int
    public var role: String
    public var contentBlocks: Data
    public var createdAt: Date
    public init(
      id: UUID, conversationID: UUID, parentID: UUID?, sequence: Int, role: String, text: String
    ) throws {
      self.id = id
      self.conversationID = conversationID
      self.parentID = parentID
      self.sequence = sequence
      self.role = role
      contentBlocks = try Wire.encode([WireMessage.Block(text: text)])
      createdAt = .now
    }
    public func text() throws -> String {
      try Wire.decode([WireMessage.Block].self, contentBlocks).map(\.text).joined()
    }
  }
  @Model public final class Attempt {
    @Attribute(.unique) public var id: UUID
    public var conversationID: UUID
    public var requestID: UUID
    public var instanceID: UUID?
    public var userMessageID: UUID
    public var assistantMessageID: UUID
    public var parentAttemptID: UUID?
    public var retryOfID: UUID?
    public var modelPath: String
    public var requestBody: Data
    public var status: String
    public var lastSequence: Int
    public var usage: Data?
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(
      conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID, parentAttemptID: UUID?,
      retryOfID: UUID?, body: GenerateBody
    ) throws {
      id = UUID()
      self.conversationID = conversationID
      requestID = body.requestID
      self.userMessageID = userMessageID
      self.assistantMessageID = assistantMessageID
      self.parentAttemptID = parentAttemptID
      self.retryOfID = retryOfID
      modelPath = body.model.path
      requestBody = try Wire.encode(body)
      status = "pending"
      lastSequence = -1
      createdAt = .now
      updatedAt = .now
    }
  }
}
