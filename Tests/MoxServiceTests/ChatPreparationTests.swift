import Foundation
import MoxBootstrap
import MoxChat
import MoxDomain
import MoxPersistence
import Testing

/// Suspend the storage call without blocking an executor or substituting the database.
private actor SuspendedStore: ConversationStoring {
  let store: ConversationStore
  var pending: CheckedContinuation<Void, Never>?
  var armed = false
  var isWaiting: Bool { pending != nil }
  init(_ store: ConversationStore) { self.store = store }
  func arm() { armed = true }
  func proceed() {
    pending?.resume()
    pending = nil
  }
  func list(offset: Int) async throws -> HistoryPage<ConversationSummary> {
    try await store.list(offset: offset)
  }
  func detail(_ id: UUID, offset: Int) async throws -> ConversationSnapshot {
    try await store.detail(id, offset: offset)
  }
  func create(modelPath: String) async throws -> UUID {
    try await store.create(modelPath: modelPath)
  }
  func begin(
    conversationID: UUID, prompt: String, modelPath: String, sampling: Sampling, retryOf: UUID?
  ) async throws -> PendingAttempt {
    if armed {
      armed = false
      await withCheckedContinuation { pending = $0 }
    }
    return try await store.begin(
      conversationID: conversationID, prompt: prompt, modelPath: modelPath, sampling: sampling,
      retryOf: retryOf)
  }
  func checkpoint(
    attemptID: UUID, instanceID: UUID?, text: String, status: String, sequence: Int, usage: Usage?,
    errorCode: String?
  ) async throws {
    try await store.checkpoint(
      attemptID: attemptID, instanceID: instanceID, text: text, status: status, sequence: sequence,
      usage: usage, errorCode: errorCode)
  }
  func selectLeaf(conversationID: UUID, attemptID: UUID) async throws {
    try await store.selectLeaf(conversationID: conversationID, attemptID: attemptID)
  }
  func delete(_ id: UUID) async throws { try await store.delete(id) }
}

@Test(arguments: [false, true])
func stopDuringPendingSaveNeverSubmitsGeneration(quit: Bool) async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let ownership = try files.lock()
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let store = try await ConversationStore.open(root: root)
  let barrier = SuspendedStore(store)
  _ = try await store.create(modelPath: model.directory.path)
  try await withService(rootIdentity: files.rootIdentity) { client, runtime in
    try files.publish(client.discovery)
    let chat = await ChatController(
      root: root.path, executable: URL(fileURLWithPath: "/never-launch"),
      openStore: { _ in barrier })
    await chat.start()
    await MainActor.run { chat.draft = "cancel-before-request" }
    await barrier.arm()
    defer { Task { await barrier.proceed() } }
    let sending = Task { await chat.send() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !barrier.isWaiting, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await barrier.isWaiting)
    #expect(await chat.isWorking)
    if quit { #expect(await chat.prepareToQuit()) }
    await chat.stop()
    #expect(await chat.isStopping)
    await barrier.proceed()
    await sending.value
    #expect(await chat.isWorking == false)
    #expect(await chat.live?.status == "cancelled")
    #expect(await chat.live?.saved == true)
    #expect(try await store.testSnapshots().first?.attempts.first?.status == "cancelled")
    #expect(try await client.state().revision == 0)
    #expect(await runtime.snapshot().activeLeases == 0)
    #expect(await chat.shutdown())
    if !quit {
      await MainActor.run { chat.draft = "next request" }
      await chat.send()
      let end = ContinuousClock.now.advanced(by: .seconds(5))
      while await chat.isWorking, ContinuousClock.now < end {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(await chat.live?.status == "stop")
      #expect(try await store.testSnapshots().first?.attempts.count == 2)
    }
  }
  withExtendedLifetime(ownership) {}
}

@Test func rejectedModelRemainsFailedWithoutLosingService() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let ownership = try files.lock()
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService(rootIdentity: files.rootIdentity) { client, runtime in
    try files.publish(client.discovery)
    let chat = await ChatController(
      root: root.path, executable: URL(fileURLWithPath: "/never-launch"))
    await chat.start()
    await MainActor.run {
      chat.modelPath = root.appendingPathComponent("missing-model").path
      chat.draft = "invalid directory"
    }
    await chat.send()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await chat.isWorking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await chat.isWorking == false)
    #expect(await chat.live?.status == "failed")
    #expect(await chat.live?.error?.code == .invalidModel)
    #expect(await chat.live?.saved == true)
    #expect(await chat.selected?.attempts.first?.errorCode == "invalidModel")
    #expect(await chat.servicePhase == "running")
    #expect(try await client.state().revision == 0)
    #expect(await runtime.snapshot().activeLeases == 0)
    await MainActor.run {
      chat.modelPath = model.directory.path
      chat.draft = "valid directory"
    }
    await chat.send()
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while await chat.isWorking, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await chat.live?.status == "stop")
    #expect(await chat.shutdown())
  }
  withExtendedLifetime(ownership) {}
}

@Test(arguments: [false, true])
func retryPreservesDraftAndNewSendConsumesOnlyItsOwnDraft(editDuringPreparation: Bool) async throws
{
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let ownership = try files.lock()
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let store = try await ConversationStore.open(root: root)
  let barrier = SuspendedStore(store)
  let cid = try await store.create(modelPath: model.directory.path)
  let first = try await store.begin(
    conversationID: cid, prompt: "original question",
    modelPath: model.directory.path, sampling: Sampling())
  try await store.checkpoint(
    attemptID: first.attemptID, instanceID: nil, text: "answer",
    status: "stop", sequence: 1, usage: nil, errorCode: nil)
  try await withService(rootIdentity: files.rootIdentity) { client, _ in
    try files.publish(client.discovery)
    let chat = await ChatController(
      root: root.path, executable: URL(fileURLWithPath: "/never-launch"),
      openStore: { _ in barrier })
    await chat.start()
    for retry in [true, false] {
      await MainActor.run { chat.draft = "next question" }
      await barrier.arm()
      let sending = Task { await chat.send(retryOf: retry ? first.attemptID : nil) }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await !barrier.isWaiting, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await barrier.isWaiting)
      if editDuringPreparation { await MainActor.run { chat.draft = "new typing" } }
      await barrier.proceed()
      await sending.value
      while await chat.isWorking, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await chat.isWorking == false)
      #expect(
        await chat.draft == (editDuringPreparation ? "new typing" : retry ? "next question" : ""))
      let snapshot = try await store.detail(cid)
      #expect(snapshot.attempts.last?.prompt == (retry ? "original question" : "next question"))
      #expect(await chat.live?.status == "stop")
    }
    #expect(await chat.shutdown())
  }
  withExtendedLifetime(ownership) {}
}
