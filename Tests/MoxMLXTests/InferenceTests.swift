import Foundation
import MoxCore
import MoxDomain
@testable import MoxMLX
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOX_TEST_MODEL"] != nil))
func realLocalInference() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["MOX_TEST_MODEL"])
  let tokenizer = try await LocalTokenizerLoader().load(from: URL(fileURLWithPath: path))
  for text in ["a\u{301}", "👩‍💻", "🇨🇳", "你好\n世界"] {
    let ids = tokenizer.encode(text: text, addSpecialTokens: false)
    var decoder = ScalarStreamingDecoder { tokenizer.decode(tokenIds: $0) }
    var streamed = ""
    for id in ids { streamed += try decoder.append(id) }
    streamed += try decoder.finish()
    #expect(Array(streamed.unicodeScalars) == Array(tokenizer.decode(tokenIds: ids).unicodeScalars))
  }
  let model = try LocalModel(path: path)
  let budget = try MLXBackend.recommendedBudget()
  let runtime = RuntimeCoordinator(
    backend: MLXBackend(memoryLimit: budget), policy: .init(budgetBytes: budget),
    availableMemory: { SystemMemory.availableBytes() })
  let sampling = try Sampling(maxTokens: 24, temperature: 0)
  var session = ChatSession()
  var firstReply = ""
  let first = try await runtime.generate(
    model: model,
    request: session.request(prompt: "Remember this word: ocean. Reply OK.", sampling: sampling))
  var terminalCount = 0
  for await event in first.events {
    if case .contentDelta(let text) = event.payload { firstReply += text }
    if case .usage(let usage) = event.payload {
      #expect(usage.outputTokens > 0)
      print(
        "REAL usage prompt=\(usage.promptTokens) output=\(usage.outputTokens) prefill=\(usage.prefillSeconds) decode=\(usage.decodeSeconds)"
      )
    }
    if case .finished(let reason) = event.payload {
      #expect(reason != .cancelled)
      terminalCount += 1
      session.complete(
        prompt: "Remember this word: ocean. Reply OK.", reply: firstReply, reason: reason)
    }
    if case .failed(let error) = event.payload { Issue.record("Real inference failed: \(error)") }
  }
  await first.waitUntilStopped()
  #expect(!firstReply.isEmpty)
  #expect(terminalCount == 1)
  let long = try await runtime.generate(
    model: model,
    request: session.request(
      prompt: "Write a very long story about that word.",
      sampling: Sampling(maxTokens: 2048, temperature: 0)))
  var cancelled = false
  var started: ContinuousClock.Instant?
  for await event in long.events {
    if case .contentDelta = event.payload, started == nil {
      started = .now
      long.cancel()
      long.cancel()
    }
    if case .finished(.cancelled) = event.payload { cancelled = true }
    if case .failed(let error) = event.payload { Issue.record("Cancellation failed: \(error)") }
  }
  await long.waitUntilStopped()
  #expect(cancelled)
  if let started { print("REAL cancel_wait=\(started.duration(to: .now))") }
  #expect(await runtime.snapshot().activeLeases == 0)
  let again = try await runtime.generate(
    model: model,
    request: session.request(prompt: "What word did I ask you to remember?", sampling: sampling))
  var againReply = ""
  for await event in again.events {
    if case .contentDelta(let text) = event.payload { againReply += text }
    if case .failed(let error) = event.payload { Issue.record("Retry failed: \(error)") }
  }
  await again.waitUntilStopped()
  #expect(!againReply.isEmpty)
  print("REAL first=\(firstReply) again=\(againReply)")
  let length = try await runtime.generate(
    model: model,
    request: .init(
      messages: [.init(role: .user, text: "Count from one to ten.")],
      sampling: Sampling(maxTokens: 1, temperature: 0)))
  var lengthEnded = false
  for await event in length.events {
    if case .finished(.length) = event.payload { lengthEnded = true }
  }
  await length.waitUntilStopped()
  #expect(lengthEnded)
  let oversized = try await runtime.generate(
    model: model,
    request: .init(
      messages: [.init(role: .user, text: String(repeating: "word ", count: 10_000))],
      sampling: sampling))
  var contextRejected = false
  for await event in oversized.events {
    if case .failed(let error) = event.payload { contextRejected = error.code == .contextLimit }
  }
  await oversized.waitUntilStopped()
  #expect(contextRejected)
  let slow = try await runtime.generate(
    model: model,
    request: .init(
      messages: [
        .init(
          role: .user,
          text: "Write a detailed 2000-word essay about the history of mathematics, with many long paragraphs.")
      ], sampling: Sampling(maxTokens: 2048, temperature: 0)))
  await slow.waitUntilStopped()
  var overflowed = false
  for await event in slow.events {
    if case .failed(let error) = event.payload { overflowed = error.code == .slowConsumer }
  }
  #expect(overflowed)
  #expect(await runtime.snapshot().activeLeases == 0)
  await runtime.shutdown()
  #expect(await runtime.snapshot().reservedBytes == 0)
  #expect(await runtime.snapshot().residentModels == 0)
}
