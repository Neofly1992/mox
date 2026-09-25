import Foundation
import MoxDomain

/// Chat use cases depend on durable operations, not on SwiftData's concrete executor.
public protocol ConversationStoring: Actor {
  func list(offset: Int) async throws -> HistoryPage<ConversationSummary>
  func detail(_ id: UUID, offset: Int) async throws -> ConversationSnapshot
  func create(modelPath: String) async throws -> UUID
  func begin(
    conversationID: UUID, prompt: String, modelPath: String, sampling: Sampling, retryOf: UUID?
  ) async throws -> PendingAttempt
  func checkpoint(
    attemptID: UUID, instanceID: UUID?, text: String, status: String, sequence: Int, usage: Usage?,
    errorCode: String?) async throws
  func selectLeaf(conversationID: UUID, attemptID: UUID) async throws
  func delete(_ id: UUID) async throws
}

extension ConversationStore: ConversationStoring {}
