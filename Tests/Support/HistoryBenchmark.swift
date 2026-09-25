import Darwin
import Foundation
import MoxDomain
import MoxPersistence

/// Run seed and read in separate processes so seeding allocations cannot bias read RSS.
enum HistoryBenchmark {
  static func seed(root: URL, modelPath: String, conversations: Int, attempts: Int, replyBytes: Int)
    async throws
  {
    let store = try await ConversationStore.open(root: root)
    let reply = String(repeating: "x", count: replyBytes)
    for _ in 0..<conversations {
      let id = try await store.create(modelPath: modelPath)
      for index in 0..<attempts {
        let pending = try await store.begin(
          conversationID: id, prompt: "History question \(index)",
          modelPath: modelPath, sampling: Sampling())
        try await store.checkpoint(
          attemptID: pending.attemptID, instanceID: nil, text: reply,
          status: "cancelled", sequence: 1, usage: nil, errorCode: nil)
      }
    }
  }
  static func read(root: URL) async throws {
    let opened = ProcessInfo.processInfo.systemUptime
    let store = try await ConversationStore.open(root: root)
    let openSeconds = ProcessInfo.processInfo.systemUptime - opened
    let began = ProcessInfo.processInfo.systemUptime
    let list = try await store.list()
    let listSeconds = ProcessInfo.processInfo.systemUptime - began
    let summaryDecodedBytes = await store.readMetrics.decodedBytes
    guard let first = list.items.first(where: { $0.status != "empty" }), summaryDecodedBytes == 0
    else {
      throw MoxError(.storageFailed, "History summary read bodies or returned no fixtures.")
    }
    let newBegan = ProcessInfo.processInfo.systemUptime
    _ = try await store.create(modelPath: "/new-empty")
    let createSeconds = ProcessInfo.processInfo.systemUptime - newBegan
    guard await store.readMetrics.decodedBytes == 0 else {
      throw MoxError(.storageFailed, "Creating a conversation read existing bodies.")
    }
    let detailBegan = ProcessInfo.processInfo.systemUptime
    let detail = try await store.detail(first.id)
    let detailSeconds = ProcessInfo.processInfo.systemUptime - detailBegan
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
      throw MoxError(.storageFailed, "Unable to measure history process memory.")
    }
    let result: [String: Double] = [
      "openSeconds": openSeconds, "listSeconds": listSeconds, "createSeconds": createSeconds,
      "detailSeconds": detailSeconds, "peakRSSBytes": Double(usage.ru_maxrss),
      "summaryDecodedBytes": Double(summaryDecodedBytes),
      "detailDecodedBytes": Double(await store.readMetrics.decodedBytes),
      "visibleAttempts": Double(detail.attempts.count),
      "visibleSummaries": Double(list.items.count),
    ]
    print(
      String(
        decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
        as: UTF8.self))
  }
}
