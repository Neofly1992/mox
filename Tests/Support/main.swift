import Foundation
import MoxBootstrap
import MoxCore
import MoxDomain
import MoxPersistence
import MoxProtocol
import MoxServer

// Isolated test executable, never bundled in the app or exposed through its protocol.
@main struct FixtureMain {
  static func main() async throws {
    let args = CommandLine.arguments
    let mode = args[1]
    let root = URL(fileURLWithPath: args[2])
    if mode == "history-benchmark-seed" {
      guard args.count > 3, let count = Int(args[3]), (1...120).contains(count) else {
        throw MoxError(.invalidParameters, "Expected 1...120 benchmark conversations.")
      }
      try await HistoryBenchmark.seed(
        root: root, modelPath: "/fixture", conversations: count, attempts: 20,
        replyBytes: 128 * 1024)
      print("PASS history fixture")
      return
    }
    if mode == "history-benchmark-read" {
      try await HistoryBenchmark.read(root: root)
      return
    }
    if mode == "seed-history" {
      try await HistoryBenchmark.seed(
        root: root, modelPath: args[3], conversations: 1, attempts: 20, replyBytes: 64)
      print("PASS paged history seed")
      return
    }
    if mode == "seed" {
      let store = try await ConversationStore.open(root: root)
      _ = try await store.create(modelPath: args[3])
      // The workspace is backed by the service catalog, not conversation history.
      let library = try await RuntimeStore.open(root: root)
      let manager = try await DownloadManager.open(
        persistence: library,
        artifacts: ArtifactStore(root: root.appendingPathComponent("models")))
      await manager.waitForRecovery()
      _ = try await manager.importDirectory(path: args[3], alias: "ui-fixture")
      await manager.shutdown()
      print("PASS seed")
      return
    }
    if mode == "inspect-long-history" {
      let store = try await ConversationStore.open(root: root)
      let attempts = try await store.detail(try await store.list().items[0].id).attempts
      guard attempts.count == 2, attempts[0].reply.utf8.count >= 1_048_576,
        attempts.allSatisfy({ $0.status == "cancelled" }),
        attempts[1].retryOfID == attempts[0].id,
        attempts[1].requestID != attempts[0].requestID
      else {
        throw MoxError(.storageFailed, "Long history/branch check failed.")
      }
      print(
        "PASS long-history attempts=2 bytes=\(attempts[0].reply.utf8.count),\(attempts[1].reply.utf8.count) cancelled=true retryPreserved=true"
      )
      return
    }
    if mode.hasPrefix("store-") {
      let store = try await ConversationStore.open(root: root)
      if mode == "store-write" {
        let id = try await store.create(modelPath: "/fixture")
        let p = try await store.begin(
          conversationID: id, prompt: "persisted question", modelPath: "/fixture",
          sampling: Sampling())
        try await store.checkpoint(
          attemptID: p.attemptID, instanceID: nil, text: "持久化 partial 👩‍💻", status: "streaming",
          sequence: 3, usage: nil, errorCode: nil)
      } else {
        let list = [try await store.detail(try await store.list().items[0].id)]
        guard list.count == 1, list[0].attempts[0].status == "interrupted",
          list[0].attempts[0].reply == "持久化 partial 👩‍💻"
        else { throw MoxError(.storageFailed, "Reopen mismatch") }
      }
      print("PASS \(mode)")
      return
    }
    let files = try ServiceFiles(path: root.path)
    let lock = try files.lock()
    let identity = ServiceIdentity(
      pid: getpid(), uid: getuid(), rootIdentity: files.rootIdentity, ownership: .externallyManaged)
    let token = try ServiceFiles.token()
    let runtime = RuntimeCoordinator(
      backend: FixtureBackend(), policy: .init(budgetBytes: 2 * 1024 * 1024 * 1024))
    let service = InferenceService(identity: identity, token: token, runtime: runtime)
    defer {
      files.remove(instanceID: identity.instanceID)
      withExtendedLifetime(lock) {}
    }
    try await PrivateServer(service: service).run { port in
      try? files.publish(
        Discovery(identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: token))
      print("READY")
    }
  }
}
struct FixtureBackend: RuntimeBackend {
  func load(_ model: LocalModel) async throws -> any LoadedModel { Loaded() }
  struct Loaded: LoadedModel {
    func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
      -> BackendResult
    {
      let prompt = try request.messages.last!.text()
      let large = prompt.contains("LONG_FIXTURE")
      for _ in 0..<(large ? 8192 : 20) {
        if !output.emit(.contentDelta(large ? String(repeating: "x", count: 1024) : "测试回复。")) {
          break
        }
        try? await Task.sleep(for: .milliseconds(large ? 5 : 30))
      }
      await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
      return .init(reason: output.isCancelled ? .cancelled : .stop)
    }
    func unload() async {}
  }
}
