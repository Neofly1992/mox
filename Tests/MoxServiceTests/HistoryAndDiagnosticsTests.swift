import Foundation
import MoxBootstrap
import MoxChat
import MoxDomain
import MoxPersistence
import MoxProtocol
import SwiftData
import Testing

@Test func historyPagesAvoidUnrelatedBodiesAndKeepAllAttempts() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await ConversationStore.open(root: root)
  let text = String(repeating: "x", count: 128 * 1024)
  // 120 conversations / 480 replies / 60 MiB; more than one summary page.
  for index in 0..<120 {
    let id = try await store.create(modelPath: "/fixture/\(index)")
    for _ in 0..<4 {
      let pending = try await store.begin(
        conversationID: id, prompt: "question",
        modelPath: "/fixture", sampling: Sampling())
      try await store.checkpoint(
        attemptID: pending.attemptID, instanceID: nil, text: text,
        status: "cancelled", sequence: 1, usage: nil, errorCode: nil)
    }
  }
  let before = await store.readMetrics
  let began = ContinuousClock.now
  let page = try await store.list()
  let summaryTime = began.duration(to: .now)
  #expect(page.items.count == HistoryLimit.conversations && page.hasMore)
  #expect(await store.readMetrics.decodedMessages == before.decodedMessages)
  let next = try await store.list(offset: HistoryLimit.conversations)
  #expect(next.items.count == 20 && !next.hasMore)
  #expect(Set(page.items.map(\.id)).isDisjoint(with: next.items.map(\.id)))
  let longID = try await store.create(modelPath: "/long")
  var ids = Set<UUID>()
  for _ in 0..<20 {
    let pending = try await store.begin(
      conversationID: longID, prompt: "long question",
      modelPath: "/long", sampling: Sampling())
    ids.insert(pending.attemptID)
    try await store.checkpoint(
      attemptID: pending.attemptID, instanceID: nil, text: text,
      status: "cancelled", sequence: 1, usage: nil, errorCode: nil)
  }
  let detailBegan = ContinuousClock.now
  var offset = 0
  var found = Set<UUID>()
  repeat {
    let value = try await store.detail(longID, offset: offset)
    #expect(value.attempts.count <= HistoryLimit.attempts)
    found.formUnion(value.attempts.map(\.id))
    if !value.hasMore { break }
    offset += HistoryLimit.attempts
  } while true
  #expect(found == ids)
  #expect(await store.readMetrics.decodedMessages - before.decodedMessages == 40)
  print(
    "HISTORY conversations=121 attempts=500 replyBytes=65536000 summary=\(summaryTime) detailAllPages=\(detailBegan.duration(to: .now)) decodedMessages=40"
  )

  let chat = await ChatController(
    root: root.path, executable: URL(fileURLWithPath: "/never-launch"),
    openStore: { _ in store })
  // Exercise storage-only operations without starting a worker.
  await chat.start()
  let readBeforeNew = await store.readMetrics.decodedMessages
  await chat.newConversation()
  #expect(await store.readMetrics.decodedMessages == readBeforeNew)
  let otherID = try #require(page.items.first?.id)
  await MainActor.run {
    chat.select(longID)
    chat.select(otherID)
  }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while await chat.selected?.id != otherID, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(await chat.selected?.id == otherID)
  #expect(await chat.replySegments.count <= HistoryLimit.attempts)
  #expect(await chat.shutdown())
}

@Test(arguments: [NSCocoaErrorDomain, NSPOSIXErrorDomain])
func storeOpenDiagnosticsPreserveSafeMetadata(domain: String) async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appendingPathComponent("existing-data")
  let sentinel = "PRIVATE-PATH-AND-CONTENT-SENTINEL"
  try Data(sentinel.utf8).write(to: marker)
  let systemCode = domain == NSCocoaErrorDomain ? 134100 : 13
  let chat = await ChatController(
    root: root.path, executable: URL(fileURLWithPath: "/never-launch"),
    openStore: { url in
      try await ConversationStore.open(
        root: url,
        makeContainer: { _ in
          throw NSError(
            domain: domain, code: systemCode,
            userInfo: [NSLocalizedDescriptionKey: sentinel, NSFilePathErrorKey: sentinel])
        })
    })
  await chat.start()
  #expect(await !chat.storageAvailable)
  #expect(await chat.connection == nil)
  let data = try await chat.diagnostics()
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let failure = try #require(json["operationFailure"] as? [String: Any])
  #expect(failure["stage"] as? String == "open")
  #expect(failure["domain"] as? String == domain)
  #expect(failure["systemCode"] as? Int == systemCode)
  #expect(json["errorCode"] as? String == "storageFailed")
  #expect(!String(decoding: data, as: UTF8.self).contains(sentinel))
  #expect(try Data(contentsOf: marker) == Data(sentinel.utf8))
}

@Test func storageDiagnosticStagesAndUnknownDomainsAreSafe() throws {
  for stage in [StorageFailure.Stage.open, .recover, .fetch, .save] {
    let failure = StorageFailure.capture(
      NSError(
        domain: "SECRET-DOMAIN", code: 99,
        userInfo: [NSLocalizedDescriptionKey: "SECRET-DESCRIPTION"]), stage: stage)
    let encoded = try JSONEncoder().encode(failure)
    #expect(failure.stage == stage && failure.domain == "redacted" && failure.systemCode == nil)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("SECRET"))
  }
}

@Test func historyPageByteBudgetDoesNotTruncateLargeReplies() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await ConversationStore.open(root: root)
  let id = try await store.create(modelPath: "/fixture")
  let reply = String(repeating: "x", count: HistoryLimit.pageTextBytes + 1)
  var ids: [UUID] = []
  for _ in 0..<3 {
    let pending = try await store.begin(
      conversationID: id, prompt: "q", modelPath: "/fixture", sampling: Sampling())
    ids.append(pending.attemptID)
    try await store.checkpoint(
      attemptID: pending.attemptID, instanceID: nil, text: reply,
      status: "cancelled", sequence: 1, usage: nil, errorCode: nil)
  }
  for offset in 0..<3 {
    let page = try await store.detail(id, offset: offset)
    #expect(page.attempts.count == 1)
    #expect(page.attempts[0].id == ids[2 - offset])
    #expect(page.attempts[0].reply == reply)
    #expect(page.hasMore == (offset < 2))
  }
}

@Test func migrationPreservesMessagesAndCompactsRequestSnapshots() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("conversations")
  try ServiceFiles.secureDirectory(directory)
  let cid = UUID()
  let aid = try await writeLegacyConversation(directory: directory, conversationID: cid)
  let store = try await ConversationStore.open(root: root)
  let detail = try await store.detail(cid)
  #expect(detail.attempts.count == 1)
  #expect(detail.attempts[0].id == aid)
  #expect(detail.attempts[0].prompt == "legacy question")
  #expect(detail.attempts[0].reply == "legacy answer")
  #expect(detail.selectedLeafID == aid)
  let next = try await store.begin(
    conversationID: cid, prompt: "next", modelPath: "/fixture", sampling: Sampling())
  #expect(next.request.messages.count == 3)
  let container = await store.modelContainer
  try await MainActor.run {
    let context = ModelContext(container)
    let attempts = try context.fetch(FetchDescriptor<ChatSchema.Attempt>())
    #expect(attempts.count == 2)
    for attempt in attempts {
      #expect(attempt.requestParameters.count < 128)
      #expect(!String(decoding: attempt.requestParameters, as: UTF8.self).contains("messages"))
    }
  }
}

@MainActor private func writeLegacyConversation(directory: URL, conversationID: UUID) async throws
  -> UUID
{
  let container = try await ConversationContainerFactory.shared.create(
    in: directory,
    schema: ChatSchemaV1.self, migrationPlan: nil)
  let context = ModelContext(container)
  let c = ChatSchemaV1.Conversation(id: conversationID, title: "legacy", localModelPath: "/fixture")
  let user = try ChatSchemaV1.MessageRecord(
    id: UUID(), conversationID: conversationID,
    parentID: nil, sequence: 0, role: "user", text: "legacy question")
  let reply = try ChatSchemaV1.MessageRecord(
    id: UUID(), conversationID: conversationID,
    parentID: user.id, sequence: 1, role: "assistant", text: "legacy answer")
  let request = try GenerationRequest(
    messages: [.init(role: .user, text: "legacy question")], sampling: Sampling())
  let a = try ChatSchemaV1.Attempt(
    conversationID: conversationID, userMessageID: user.id,
    assistantMessageID: reply.id, parentAttemptID: nil, retryOfID: nil,
    body: GenerateBody(path: "/fixture", request: request))
  a.status = "stop"
  c.selectedLeafID = a.id
  context.insert(c)
  context.insert(user)
  context.insert(reply)
  context.insert(a)
  try context.save()
  return a.id
}
