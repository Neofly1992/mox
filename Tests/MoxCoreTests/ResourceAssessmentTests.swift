import Foundation
import MoxDomain
import Testing

@testable import MoxCore

@Test func resourceEnvelopeBoundaryContextAndUnknown() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let resources = model.resources
  let small = resources.assessment(maxTokens: 1, budgetBytes: Int.max)
  let large = resources.assessment(maxTokens: 8192, budgetBytes: Int.max)
  #expect(large.kvBytes! > small.kvBytes!)
  #expect(large.contextTokens == 16384)
  let peak = try #require(small.peakBytes)
  #expect(resources.assessment(maxTokens: 1, budgetBytes: peak).status == .constrained)
  #expect(resources.assessment(maxTokens: 1, budgetBytes: peak - 1).status == .exceedsBudget)
  #expect(resources.assessment(maxTokens: Int.max, budgetBytes: peak).status == .unknown)
  #expect(
    resources.assessment(maxTokens: 1, budgetBytes: Int.max, residentBytes: Int.max).status
      == .unknown)
  #expect(throws: MoxError.self) {
    try ModelResources(configuration: Data(#"{"model_type":"unknown"}"#.utf8), weightBytes: 10)
  }
}

@Test func residentAssessmentDoesNotDoubleCountWeightsOrLoadPeak() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let coordinator = runtime(ProbeBackend())
  let unloaded = await coordinator.assess(model: model, maxTokens: 8)
  try await coordinator.load(model: model)
  let loaded = await coordinator.assess(model: model, maxTokens: 8)
  #expect(loaded.residentBytes == model.weightBytes)
  #expect(loaded.loadOverheadBytes == 0)
  #expect(unloaded.peakBytes! - loaded.peakBytes! == model.weightBytes)
  await coordinator.shutdown()
}

final class MemorySignal: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Int = 512 * 1024 * 1024
  func set(_ value: Int) { lock.withLock { bytes = value } }
  func read() -> Int { lock.withLock { bytes } }
}
@Test func previewCannotAuthorizeAfterAvailableMemoryChanges() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let signal = MemorySignal()
  let backend = ProbeBackend()
  let coordinator = RuntimeCoordinator(
    backend: backend, policy: .init(budgetBytes: 512 * 1024 * 1024),
    availableMemory: { signal.read() })
  #expect(await coordinator.assess(model: model, maxTokens: 8).status == .recommended)
  signal.set(1)
  let events = await collect(try await coordinator.generate(model: model, request: request()))
  if case .failed(let error) = events.last?.payload {
    #expect(error.code == .resourceLimit)
  } else {
    Issue.record("Expected rechecked admission rejection")
  }
  #expect(await backend.loads == 0)
  #expect(await coordinator.snapshot().reservedBytes == 0)
}

@Test func pressureStopsGenerationPreservesPinAndUsesRecoveryDebounce() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let coordinator = runtime(
    ProbeBackend(loadDelay: .zero, tokenDelay: .milliseconds(20), count: 1000))
  await coordinator.setPinned(modelID: model.id, true)
  let active = try await coordinator.generate(model: model, request: request())
  for await event in active.events {
    if case .contentDelta = event.payload {
      await coordinator.updatePressure(.critical)
      #expect(await coordinator.snapshot().reservedBytes > model.weightBytes)
      break
    }
  }
  await active.waitUntilStopped()
  #expect(await coordinator.snapshot().activeLeases == 0)
  #expect(await coordinator.snapshot().reservedBytes == model.weightBytes)
  await #expect(throws: MoxError.self) {
    try await coordinator.generate(model: model, request: request())
  }
  await coordinator.updatePressure(.normal)
  #expect(await coordinator.snapshot().admissionPaused)
  await coordinator.updatePressure(.warning)
  try await Task.sleep(for: .milliseconds(30))
  #expect(await coordinator.snapshot().pressure == .warning)
  await coordinator.updatePressure(.normal)
  try await Task.sleep(for: .milliseconds(5100))
  #expect(!(await coordinator.snapshot().admissionPaused))
  await coordinator.shutdown()
  #expect(await coordinator.snapshot().reservedBytes == 0)
}

@Test func pressureReclaimsOnlyIdleUnpinnedResidents() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let coordinator = runtime(ProbeBackend())
  try await coordinator.load(model: model)
  await coordinator.updatePressure(.warning)
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await coordinator.snapshot().reservedBytes > 0, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(await coordinator.snapshot().reservedBytes == 0)
  #expect(await coordinator.snapshot().residentModels == 0)
  await coordinator.shutdown()
}

@Test func contextEnvelopeAndImpossibleOutputAreExplainedBeforeLoad() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let config = model.directory.appendingPathComponent("config.json")
  let original = try String(contentsOf: config, encoding: .utf8)
  try Data(original.replacingOccurrences(of: "32768", with: "1024").utf8).write(to: config)
  let shorter = try LocalModel(path: model.directory.path)
  let estimate = shorter.resources.assessment(maxTokens: 8, budgetBytes: Int.max)
  #expect(estimate.contextTokens == 1024)
  #expect(
    estimate.kvBytes! < model.resources.assessment(maxTokens: 8, budgetBytes: Int.max).kvBytes!)
  #expect(
    shorter.resources.assessment(maxTokens: 1024, budgetBytes: Int.max).status == .exceedsBudget)
  let backend = ProbeBackend()
  let coordinator = runtime(backend)
  await #expect(throws: MoxError.self) {
    try await coordinator.generate(
      model: shorter,
      request: GenerationRequest(
        messages: [.init(role: .user, text: "Hi")], sampling: Sampling(maxTokens: 1024)))
  }
  #expect(await backend.loads == 0)
}

@Test func estimatorUsesLockedAdapterHeadDimensionsAndGemmaScoreWorkspace() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let config = try String(
    contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8)
  let misleading = config.replacingOccurrences(
    of: "\"hidden_size\":16", with: "\"hidden_size\":16,\"head_dim\":1")
  let qwen = try ModelResources(configuration: Data(misleading.utf8), weightBytes: 100)
  #expect(qwen.kvBytesPerToken == model.kvBytesPerToken)
  let largeMLP = try ModelResources(
    configuration: Data(
      config.replacingOccurrences(
        of: "\"intermediate_size\":64", with: "\"intermediate_size\":1000000"
      ).utf8), weightBytes: 100)
  #expect(largeMLP.workspaceBytes > qwen.workspaceBytes)
  #expect(throws: MoxError.self) {
    try ModelResources(
      configuration: Data(
        config.replacingOccurrences(of: "\"intermediate_size\":64,", with: "").utf8),
      weightBytes: 100)
  }
  let gemmaConfig = misleading.replacingOccurrences(of: "qwen2", with: "gemma2")
    .replacingOccurrences(of: "\"head_dim\":1", with: "\"head_dim\":256")
    .replacingOccurrences(of: "\"num_attention_heads\":2", with: "\"num_attention_heads\":64")
  let gemma = try ModelResources(configuration: Data(gemmaConfig.utf8), weightBytes: 100)
  #expect(gemma.workspaceBytes > model.workspaceBytes)
  #expect(throws: MoxError.self) {
    try ModelResources(
      configuration: Data(config.replacingOccurrences(of: "qwen2", with: "gemma2").utf8),
      weightBytes: 100)
  }
}

@Test func explicitLoadIncludesWarmupWorkspaceBeforeBackendAllocation() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend()
  let coordinator = RuntimeCoordinator(
    backend: backend,
    policy: .init(budgetBytes: model.weightBytes * 2))
  await #expect(throws: MoxError.self) { try await coordinator.load(model: model) }
  #expect(await backend.loads == 0)
  #expect(await coordinator.snapshot().reservedBytes == 0)
}

private struct CappedBackend: RuntimeBackend {
  let probe: ProbeBackend
  var memoryBudgetCeilingBytes: Int? { 64 * 1024 * 1024 }
  func load(_ model: LocalModel) async throws -> any LoadedModel { try await probe.load(model) }
}
@Test func directCorePolicyCannotRaiseBackendSafetyCeiling() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let probe = ProbeBackend()
  let coordinator = RuntimeCoordinator(
    backend: CappedBackend(probe: probe), policy: .init(budgetBytes: Int.max))
  #expect(await coordinator.snapshot().budgetBytes == 64 * 1024 * 1024)
  await #expect(throws: MoxError.self) { try await coordinator.load(model: model) }
  #expect(await probe.loads == 0)
}
