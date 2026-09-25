import Foundation
import MoxBootstrap
import MoxDomain
import SwiftData

public struct AttemptSnapshot: Identifiable, Sendable {
  public var canContinue: Bool { FinishReason(rawValue: status)?.includesTurnInContext == true }
  public let id: UUID
  public let requestID: UUID
  public let instanceID: UUID?
  public let parentAttemptID: UUID?
  public let retryOfID: UUID?
  public let prompt: String
  public let reply: String
  public let modelPath: String
  public let status: String
  public let errorCode: String?
  public let lastSequence: Int
  public let usage: Usage?
}
public struct ConversationSnapshot: Identifiable, Sendable {
  public let updatedAt: Date
  public let id: UUID
  public let title: String
  public let modelPath: String
  public let selectedLeafID: UUID?
  public let attempts: [AttemptSnapshot]
  public let offset: Int
  public let hasMore: Bool
}
public struct PendingAttempt: Sendable {
  public let attemptID: UUID
  public let modelPath: String
  public let request: GenerationRequest
}

@ModelActor public actor ConversationStore {
  private static let recoveryBatchSize = 128
  public private(set) var readMetrics = HistoryReadMetrics()
  private var ownership: DirectoryLock?
  private var commit: @Sendable (ModelContext) throws -> Void = { try $0.save() }
  public static func open(
    root: URL, commit: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
    makeContainer: @escaping @Sendable (URL) async throws -> ModelContainer = {
      try await ConversationContainerFactory.shared.create(in: $0)
    }
  ) async throws -> ConversationStore {
    do {
      return try await Task.detached {
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        try ServiceFiles.secureDirectory(directory)
        let lock = try DirectoryLock(directory: directory, name: "writer.lock")
        let container = try await makeContainer(directory)
        let store = ConversationStore(modelContainer: container)
        await store.own(lock, commit: commit)
        try await store.recover()
        return store
      }.value
    } catch { throw StorageFailure.capture(error, stage: .open) }
  }
  private func own(_ lock: DirectoryLock, commit: @escaping @Sendable (ModelContext) throws -> Void)
  {
    ownership = lock
    self.commit = commit
    modelContext.autosaveEnabled = false
  }
  private func save() throws {
    do { try commit(modelContext) } catch {
      modelContext.rollback()
      throw StorageFailure.capture(error, stage: .save)
    }
  }
  private func recover() throws {
    try operation(.recover) {
      // Fetch only interrupted candidates, in bounded batches; no message bodies are touched.
      var query = FetchDescriptor<ChatSchema.Attempt>(
        predicate: #Predicate {
          $0.status == "pending" || $0.status == "streaming" || $0.status == "stopping"
        })
      query.fetchLimit = Self.recoveryBatchSize
      while true {
        let batch = try modelContext.fetch(query)
        if batch.isEmpty { break }
        for attempt in batch {
          attempt.status = "interrupted"
          attempt.errorCode = "appInterrupted"
          attempt.updatedAt = .now
        }
        try save()
      }
    }
  }
  private func operation<T>(_ stage: StorageFailure.Stage, _ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw StorageFailure.capture(error, stage: stage) }
  }
  private func text(_ id: UUID) throws -> String {
    let value = try message(id).text()
    readMetrics.decodedMessages += 1
    readMetrics.decodedBytes += value.utf8.count
    return value
  }
  private func conversation(_ id: UUID) throws -> ChatSchema.Conversation {
    guard
      let c = try modelContext.fetch(
        FetchDescriptor<ChatSchema.Conversation>(predicate: #Predicate { $0.id == id })
      ).first
    else { throw MoxError(.notFound, "Conversation not found.") }
    return c
  }
  private func attempt(_ id: UUID) throws -> ChatSchema.Attempt {
    guard
      let a = try modelContext.fetch(
        FetchDescriptor<ChatSchema.Attempt>(predicate: #Predicate { $0.id == id })
      ).first
    else { throw MoxError(.notFound, "Attempt not found.") }
    return a
  }
  private func message(_ id: UUID) throws -> ChatSchema.MessageRecord {
    guard
      let m = try modelContext.fetch(
        FetchDescriptor<ChatSchema.MessageRecord>(predicate: #Predicate { $0.id == id })
      ).first
    else { throw MoxError(.storageFailed, "Conversation message is missing.") }
    return m
  }
  public func list(offset: Int = 0) throws -> HistoryPage<ConversationSummary> {
    try operation(.fetch) {
      guard offset >= 0 else { throw MoxError(.invalidParameters, "Invalid history offset.") }
      var query = FetchDescriptor<ChatSchema.Conversation>(sortBy: [
        SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse),
      ])
      query.fetchOffset = offset
      query.fetchLimit = HistoryLimit.conversations + 1
      let records = try modelContext.fetch(query)
      let summaries = try records.prefix(HistoryLimit.conversations).map { c in
        let cid = c.id
        var latest = FetchDescriptor<ChatSchema.Attempt>(
          predicate: #Predicate { $0.conversationID == cid },
          sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        latest.fetchLimit = 1
        latest.propertiesToFetch = [\.status]
        return ConversationSummary(
          id: c.id, title: c.title, modelPath: c.localModelPath,
          updatedAt: c.updatedAt, status: try modelContext.fetch(latest).first?.status ?? "empty")
      }
      return HistoryPage(
        items: summaries, offset: offset, hasMore: records.count > HistoryLimit.conversations)
    }
  }
  public func detail(_ id: UUID, offset: Int = 0) throws -> ConversationSnapshot {
    try operation(.fetch) {
      guard offset >= 0 else { throw MoxError(.invalidParameters, "Invalid history offset.") }
      let c = try conversation(id)
      var query = FetchDescriptor<ChatSchema.Attempt>(
        predicate: #Predicate { $0.conversationID == id },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
      query.fetchOffset = offset
      query.fetchLimit = HistoryLimit.attempts + 1
      let attempts = try modelContext.fetch(query)
      var snapshots: [AttemptSnapshot] = []
      var textBytes = 0
      for attempt in attempts.prefix(HistoryLimit.attempts) {
        let prompt = try text(attempt.userMessageID)
        let reply = try text(attempt.assistantMessageID)
        let bytes = prompt.utf8.count + reply.utf8.count
        if !snapshots.isEmpty, textBytes + bytes > HistoryLimit.pageTextBytes { break }
        snapshots.append(
          AttemptSnapshot(
            id: attempt.id, requestID: attempt.requestID, instanceID: attempt.instanceID,
            parentAttemptID: attempt.parentAttemptID, retryOfID: attempt.retryOfID,
            prompt: prompt, reply: reply, modelPath: attempt.modelPath,
            status: attempt.status, errorCode: attempt.errorCode,
            lastSequence: attempt.lastSequence,
            usage: try attempt.usage.map { try JSONDecoder().decode(Usage.self, from: $0) }))
        textBytes += bytes
      }
      return ConversationSnapshot(
        updatedAt: c.updatedAt, id: c.id, title: c.title,
        modelPath: c.localModelPath, selectedLeafID: c.selectedLeafID,
        attempts: snapshots.reversed(),
        offset: offset, hasMore: attempts.count > snapshots.count)
    }
  }
  public func create(modelPath: String) throws -> UUID {
    return try operation(.save) {
      let c = ChatSchema.Conversation(id: UUID(), title: "新对话", localModelPath: modelPath)
      modelContext.insert(c)
      try save()
      return c.id
    }
  }
  public func selectLeaf(conversationID: UUID, attemptID: UUID) throws {
    return try operation(.save) {
      let c = try conversation(conversationID)
      let a = try attempt(attemptID)
      guard a.conversationID == c.id,
        FinishReason(rawValue: a.status)?.includesTurnInContext == true
      else { throw MoxError(.invalidParameters, "Select a completed reply for context.") }
      c.selectedLeafID = a.id
      try save()
    }
  }
  public func begin(
    conversationID: UUID, prompt: String, modelPath: String, sampling: Sampling,
    retryOf: UUID? = nil
  ) throws -> PendingAttempt {
    return try operation(.fetch) {
      let c = try conversation(conversationID)
      let old = try retryOf.map { try attempt($0) }
      guard old == nil || old?.conversationID == c.id else {
        throw MoxError(.invalidParameters, "Retry belongs to another conversation.")
      }
      let parentID = old?.parentAttemptID ?? (old == nil ? c.selectedLeafID : nil)
      var messages: [Message] = []
      var contextBytes = 0
      var ancestor = parentID
      var visited = Set<UUID>()
      while let id = ancestor {
        guard visited.insert(id).inserted else {
          throw MoxError(.storageFailed, "Invalid conversation branch.")
        }
        let a = try attempt(id)
        guard FinishReason(rawValue: a.status)?.includesTurnInContext == true else {
          throw MoxError(.storageFailed, "Invalid conversation context.")
        }
        let question = try text(a.userMessageID)
        let answer = try text(a.assistantMessageID)
        contextBytes += question.utf8.count + answer.utf8.count
        guard contextBytes <= GenerationRequest.maximumInputBytes else {
          throw MoxError(.contextLimit, "Conversation context exceeds the input safety limit.")
        }
        messages.insert(
          contentsOf: [
            Message(role: .user, text: question),
            Message(role: .assistant, text: answer),
          ], at: 0)
        ancestor = a.parentAttemptID
      }
      let userText = try old.map { try message($0.userMessageID).text() } ?? prompt
      messages.append(.init(role: .user, text: userText))
      let request = try GenerationRequest(messages: messages, sampling: sampling)
      let userID = old?.userMessageID ?? UUID()
      let replyID = UUID()
      if old == nil {
        modelContext.insert(
          try ChatSchema.MessageRecord(
            id: userID, conversationID: c.id,
            parentID: try parentID.map { try attempt($0).assistantMessageID },
            sequence: messages.count - 1, role: "user", text: userText))
      }
      modelContext.insert(
        try ChatSchema.MessageRecord(
          id: replyID, conversationID: c.id, parentID: userID, sequence: messages.count,
          role: "assistant", text: ""))
      let a = try ChatSchema.Attempt(
        conversationID: c.id, userMessageID: userID, assistantMessageID: replyID,
        parentAttemptID: parentID, retryOfID: retryOf, modelPath: modelPath, request: request)
      modelContext.insert(a)
      c.localModelPath = modelPath
      c.updatedAt = .now
      if c.title == "新对话" { c.title = String(userText.prefix(40)) }
      try save()
      return PendingAttempt(attemptID: a.id, modelPath: modelPath, request: request)
    }
  }
  public func checkpoint(
    attemptID: UUID, instanceID: UUID?, text: String, status: String, sequence: Int, usage: Usage?,
    errorCode: String?
  ) throws {
    return try operation(.save) {
      let a = try attempt(attemptID)
      guard sequence >= a.lastSequence, text.utf8.count <= HistoryLimit.maximumReplyBytes else {
        throw MoxError(.storageFailed, "Invalid conversation checkpoint.")
      }
      let m = try message(a.assistantMessageID)
      m.contentBlocks = try StoredText.encode(text)
      a.instanceID = instanceID
      a.status = status
      a.lastSequence = sequence
      a.usage = try usage.map { try JSONEncoder().encode($0) }
      a.errorCode = errorCode
      a.updatedAt = .now
      let c = try conversation(a.conversationID)
      c.updatedAt = .now
      if FinishReason(rawValue: status)?.includesTurnInContext == true { c.selectedLeafID = a.id }
      try save()
    }
  }
  public func delete(_ id: UUID) throws {
    return try operation(.save) {
      for a in try modelContext.fetch(
        FetchDescriptor<ChatSchema.Attempt>(predicate: #Predicate { $0.conversationID == id }))
      { modelContext.delete(a) }
      for m in try modelContext.fetch(
        FetchDescriptor<ChatSchema.MessageRecord>(predicate: #Predicate { $0.conversationID == id })
      ) { modelContext.delete(m) }
      modelContext.delete(try conversation(id))
      try save()
    }
  }
}

/// SwiftData/Core Data share process-wide schema metadata. Serialize construction,
/// not model actors or saves: concurrent fresh-store initialization crashed inside
/// NSSQLEntity_DerivedAttributesExtension during the M2 parallel integration tests.
public actor ConversationContainerFactory {
  public static let shared = ConversationContainerFactory()
  public func create(
    in directory: URL, schema: any VersionedSchema.Type = ChatSchema.self,
    migrationPlan: (any SchemaMigrationPlan.Type)? = ChatMigration.self
  ) throws -> ModelContainer {
    let configuration = ModelConfiguration(
      url: directory.appendingPathComponent("Conversation.store"))
    return try ModelContainer(
      for: Schema(versionedSchema: schema), migrationPlan: migrationPlan,
      configurations: configuration)
  }
}
