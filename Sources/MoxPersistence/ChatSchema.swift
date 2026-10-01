import Foundation
import MoxDomain
import SwiftData

public typealias ChatSchema = ChatSchemaV2

public enum ChatSchemaV2: VersionedSchema {
  public static let versionIdentifier = Schema.Version(2, 0, 0)
  public static var models: [any PersistentModel.Type] {
    [Conversation.self, MessageRecord.self, Attempt.self]
  }
  @Model public final class Conversation {
    #Index<Conversation>([\.updatedAt, \.createdAt])
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
    #Index<MessageRecord>([\.conversationID])
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
      contentBlocks = try StoredText.encode(text)
      createdAt = .now
    }
    public func text() throws -> String {
      try StoredText.decode(contentBlocks)
    }
  }
  @Model public final class Attempt {
    #Index<Attempt>([\.conversationID, \.createdAt], [\.status])
    @Attribute(.unique) public var id: UUID
    public var conversationID: UUID
    public var requestID: UUID
    public var instanceID: UUID?
    public var userMessageID: UUID
    public var assistantMessageID: UUID
    public var parentAttemptID: UUID?
    public var retryOfID: UUID?
    public var modelPath: String
    @Attribute(originalName: "requestBody") public var requestParameters: Data
    public var status: String
    public var lastSequence: Int
    public var usage: Data?
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(
      conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID, parentAttemptID: UUID?,
      retryOfID: UUID?, modelPath: String, request: GenerationRequest
    ) throws {
      id = UUID()
      self.conversationID = conversationID
      requestID = request.id
      self.userMessageID = userMessageID
      self.assistantMessageID = assistantMessageID
      self.parentAttemptID = parentAttemptID
      self.retryOfID = retryOfID
      self.modelPath = modelPath
      requestParameters = try JSONEncoder().encode(StoredSampling(request.sampling))
      status = "pending"
      lastSequence = -1
      createdAt = .now
      updatedAt = .now
    }
  }
}

/// Storage owns its representation; HTTP DTO changes do not alter this schema.
struct StoredText: Codable {
  let type: String
  let text: String
  static func encode(_ text: String) throws -> Data {
    try JSONEncoder().encode([StoredText(type: "text", text: text)])
  }
  static func decode(_ data: Data) throws -> String {
    let blocks = try JSONDecoder().decode([StoredText].self, from: data)
    guard blocks.allSatisfy({ $0.type == "text" }) else {
      throw MoxError(.storageFailed, "Unsupported stored content.")
    }
    return blocks.map(\.text).joined()
  }
}
struct StoredSampling: Codable {
  let maxTokens: Int
  let temperature: Float
  let topP: Float
  init(_ sampling: Sampling) {
    maxTokens = sampling.maxTokens
    temperature = sampling.temperature
    topP = sampling.topP
  }
}
