import Foundation
import MoxDomain
import Testing

@testable import MoxCore

func fixture() throws -> LocalModel {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mox 测试 \(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let config =
    #"{"model_type":"qwen2","hidden_size":16,"intermediate_size":64,"num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,"max_position_embeddings":32768,"vocab_size":100}"#
  try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
  for file in ["tokenizer_config.json", "tokenizer.json"] {
    try Data("{}".utf8).write(to: root.appendingPathComponent(file))
  }
  let header = Data(#"{"test":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
  var length = UInt64(header.count).littleEndian
  var weights = withUnsafeBytes(of: &length) { Data($0) }
  weights.append(header)
  weights.append(Data(repeating: 0, count: 4))
  try weights.write(to: root.appendingPathComponent("model.safetensors"))
  return try LocalModel(path: root.path)
}
actor ProbeBackend: RuntimeBackend {
  var loads = 0
  var failures: Int
  let loadDelay: Duration
  let tokenDelay: Duration
  let count: Int
  init(
    failures: Int = 0, loadDelay: Duration = .milliseconds(30),
    tokenDelay: Duration = .milliseconds(2), count: Int = 10
  ) {
    self.failures = failures
    self.loadDelay = loadDelay
    self.tokenDelay = tokenDelay
    self.count = count
  }
  func load(_ model: LocalModel) async throws -> any LoadedModel {
    loads += 1
    try await Task.sleep(for: loadDelay)
    if failures > 0 {
      failures -= 1
      throw MoxError(.loadFailed, "Injected load failure")
    }
    return ProbeLoaded(delay: tokenDelay, count: count)
  }
}
struct ProbeLoaded: LoadedModel {
  let delay: Duration
  let count: Int
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  {
    for _ in 0..<count {
      if output.isCancelled { break }
      if !output.emit(.contentDelta("x")) { break }
      if delay > .zero { try? await Task.sleep(for: delay) }
    }
    // Simulates the backend's noninstantaneous cancellation/GPU completion barrier.
    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
    return BackendResult(reason: output.isCancelled ? .cancelled : .length)
  }
  func unload() async {}
}
func collect(_ handle: GenerationHandle) async -> [GenerationEvent] {
  var events: [GenerationEvent] = []
  for await event in handle.events { events.append(event) }
  await handle.waitUntilStopped()
  #expect(events.filter { $0.payload.isTerminal }.count == 1)
  #expect(events.map(\.sequence) == Array(0..<events.count))
  #expect(events.last?.payload.isTerminal == true)
  return events
}
func request() throws -> GenerationRequest {
  try .init(
    messages: [.init(role: .user, text: "private prompt")], sampling: Sampling(maxTokens: 8))
}
func runtime(_ backend: ProbeBackend, queue: Int = 8, timeout: Duration = .seconds(60))
  -> RuntimeCoordinator
{
  RuntimeCoordinator(
    backend: backend,
    policy: .init(budgetBytes: 512 * 1024 * 1024, queueCapacity: queue, queueTimeout: timeout))
}
@Test func explicitLoadFailureReleasesTaskAndReservation() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend(failures: 1)
  let core = runtime(backend)
  await #expect(throws: MoxError.self) { try await core.load(model: model) }
  #expect(await core.snapshot().reservedBytes == 0)
  #expect(await core.modelStates().isEmpty)
  try await core.load(model: model)
  #expect(await backend.loads == 2)
  #expect(await core.snapshot().residentModels == 1)
  await core.shutdown()
}
@Test func parametersAndSession() throws {
  for tokens in [0, -1, 8193] { #expect(throws: MoxError.self) { try Sampling(maxTokens: tokens) } }
  for temperature: Float in [.nan, .infinity, -1, 3] {
    #expect(throws: MoxError.self) { try Sampling(temperature: temperature) }
  }
  for p: Float in [0, -1, .nan, 2] { #expect(throws: MoxError.self) { try Sampling(topP: p) } }
  #expect(try Sampling().maxTokens == 2048)
  #expect(throws: MoxError.self) {
    try GenerationRequest(
      messages: [.init(role: .user, content: [.media(assetID: "x", mediaType: "image")])],
      sampling: Sampling())
  }
  var session = ChatSession()
  session.complete(prompt: "bad", reply: "partial", reason: .cancelled)
  #expect(session.messages.isEmpty)
  session.complete(prompt: "hello", reply: "world", reason: .length)
  #expect(try session.request(prompt: "next", sampling: Sampling()).messages.count == 3)
}
@Test func samplingPriorityAndProvenance() throws {
  let effective = try EffectiveSampling.resolve(
    request: .init(temperature: 0), model: .init(maxTokens: 321, temperature: 0.8),
    launch: .init(maxTokens: 512, topP: 0.7), global: .init(maxTokens: 1024, topP: 0.9))
  #expect(effective.maxTokens == 321 && effective.maxTokensSource == .model)
  #expect(effective.temperature == 0 && effective.temperatureSource == .request)
  #expect(effective.topP == 0.7 && effective.topPSource == .launch)
  let defaulted = try EffectiveSampling.resolve()
  #expect(defaulted.maxTokensSource == .product)
  #expect(defaulted.temperatureSource == .product)
  #expect(defaulted.topPSource == .product)
  #expect(throws: MoxError.self) {
    try EffectiveSampling.resolve(global: .init(temperature: .nan))
  }
}

@Test func initialLibraryFormatRejectsMissingRequiredState() throws {
  let snapshot = ModelLibrarySnapshot(installations: [
    ModelInstallation(path: "/fixture", manifest: nil, alias: "fixture")])
  let data = try JSONEncoder().encode(snapshot)
  let reopened = try JSONDecoder().decode(ModelLibrarySnapshot.self, from: data)
  #expect(reopened.installations == snapshot.installations)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "configuration")
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ModelLibrarySnapshot.self,
      from: JSONSerialization.data(withJSONObject: object))
  }
  object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var installations = try #require(object["installations"] as? [[String: Any]])
  installations[0].removeValue(forKey: "availability")
  object["installations"] = installations
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ModelLibrarySnapshot.self,
      from: JSONSerialization.data(withJSONObject: object))
  }
}
@Test func pinnedResidentCannotBeAutomaticallyEvicted() async throws {
  let first = try fixture()
  let second = try fixture()
  defer {
    try? FileManager.default.removeItem(at: first.directory)
    try? FileManager.default.removeItem(at: second.directory)
  }
  let core = RuntimeCoordinator(backend: ProbeBackend(),
    policy: .init(budgetBytes: first.resources.assessment(maxTokens: 1, budgetBytes: Int.max).peakBytes!))
  try await core.load(model: first)
  await core.setPinned(modelID: first.id, true)
  await #expect(throws: MoxError.self) { try await core.load(model: second) }
  #expect(await core.snapshot().residentModels == 1)
  await core.setPinned(modelID: first.id, false)
  try await core.load(model: second)
  #expect(await core.modelStates().map(\.id) == [second.id])
  await core.shutdown()
}
@Test func localValidation() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  #expect(
    try LocalModel(
      path: model.directory.appendingPathComponent("..").appendingPathComponent(
        model.directory.lastPathComponent
      ).path
    ).id == model.id)
  try model.validateUnchanged()
  try Data("changed".utf8).write(to: model.directory.appendingPathComponent("tokenizer.json"))
  #expect(throws: MoxError.self) { try model.validateUnchanged() }
  try FileManager.default.removeItem(at: model.directory.appendingPathComponent("config.json"))
  #expect(throws: MoxError.self) { try LocalModel(path: model.directory.path) }
  #expect(throws: MoxError.self) { try LocalModel(path: "/nonexistent-mox") }
}
@Test func sharedLoadCancellationAndReuse() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend(loadDelay: .milliseconds(80))
  let core = runtime(backend)
  let first = try await core.generate(model: model, request: request())
  let second = try await core.generate(model: model, request: request())
  try await Task.sleep(for: .milliseconds(20))
  #expect(await core.snapshot().reservedBytes > 0)
  first.cancel()
  first.cancel()
  let cancelled = await collect(first)
  if case .finished(.cancelled) = cancelled.last?.payload {
  } else {
    Issue.record("Expected cancelled")
  }
  _ = await collect(second)
  #expect(await backend.loads == 1)
  #expect(await core.snapshot().activeLeases == 0)
  let again = try await core.generate(model: model, request: request())
  _ = await collect(again)
  try await core.unload(modelID: model.id)
  #expect(await core.snapshot().reservedBytes == 0)
  #expect(await core.snapshot().residentModels == 0)
}
@Test func rollbackAndRetry() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(failures: 1))
  let failed = try await core.generate(model: model, request: request())
  let events = await collect(failed)
  if case .failed(let error) = events.last?.payload {
    #expect(error.code == .loadFailed)
  } else {
    Issue.record("Expected failure")
  }
  #expect(await core.snapshot().reservedBytes == 0)
  let retry = try await core.generate(model: model, request: request())
  _ = await collect(retry)
  await core.shutdown()
  #expect(await core.snapshot().reservedBytes == 0)
}
@Test func queueLimitsBusyAndShutdown() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(
    ProbeBackend(loadDelay: .milliseconds(150)), queue: 1, timeout: .milliseconds(40))
  let first = try await core.generate(model: model, request: request())
  try await Task.sleep(for: .milliseconds(10))
  let waiting = try await core.generate(model: model, request: request())
  try await Task.sleep(for: .milliseconds(10))
  let full = try await core.generate(model: model, request: request())
  let fullEvents = await collect(full)
  if case .failed(let error) = fullEvents.last?.payload {
    #expect(error.code == .queueFull)
  } else {
    Issue.record("Expected full queue")
  }
  do {
    try await core.unload(modelID: model.id)
    Issue.record("Busy unload succeeded")
  } catch let error as MoxError { #expect(error.code == .busy) }
  let timed = await collect(waiting)
  if case .failed(let error) = timed.last?.payload {
    #expect(error.code == .queueTimeout)
  } else {
    Issue.record("Expected deadline")
  }
  await core.shutdown()
  _ = await collect(first)
  let snapshot = await core.snapshot()
  #expect(snapshot.reservedBytes == 0 && snapshot.activeLeases == 0 && snapshot.queued == 0)
}
@Test func slowConsumerAndZeroContent() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(tokenDelay: .zero, count: 1000))
  let handle = try await core.generate(model: model, request: request())
  await handle.waitUntilStopped()
  let events = await collect(handle)
  if case .failed(let error) = events.last?.payload {
    #expect(error.code == .slowConsumer)
  } else {
    Issue.record("Expected bounded overflow")
  }
  #expect(events.count <= 129)
  #expect(await core.snapshot().activeLeases == 0)
  await core.shutdown()
  let empty = runtime(ProbeBackend(count: 0))
  _ = await collect(try await empty.generate(model: model, request: request()))
  await empty.shutdown()
}
@Test func resourceAdmissionAndTerminalRace() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = RuntimeCoordinator(backend: ProbeBackend(), policy: .init(budgetBytes: 1))
  do {
    _ = try await core.generate(model: model, request: request())
    Issue.record("Expected budget rejection")
  } catch let error as MoxError { #expect(error.code == .resourceLimit) }
  #expect(await core.snapshot().reservedBytes == 0)
  for _ in 0..<20 {
    let handle = GenerationHandle(requestID: UUID())
    async let cancel: Void = Task.detached {
      handle.cancel()
      handle.cancel()
    }.value
    async let finish: Void = Task.detached {
      handle.finish(.finished(.stop))
      handle.emit(.contentDelta("late"))
    }.value
    _ = await (cancel, finish)
    let events = await collect(handle)
    #expect(events.count == 1)
  }
}

@Test func sharedLoadFailureFansOutThenRecovers() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend(failures: 1, loadDelay: .milliseconds(60))
  let core = runtime(backend)
  let first = try await core.generate(model: model, request: request())
  let second = try await core.generate(model: model, request: request())
  for handle in [first, second] {
    let events = await collect(handle)
    if case .failed(let error) = events.last?.payload {
      #expect(error.code == .loadFailed)
    } else {
      Issue.record("Expected shared failure")
    }
  }
  #expect(await backend.loads == 1)
  #expect(await core.snapshot().reservedBytes == 0)
  let retry = try await core.generate(model: model, request: request())
  _ = await collect(retry)
  #expect(await backend.loads == 2)
  await core.shutdown()
}
@Test func cancelledQueueWaiterDoesNotAffectNeighbours() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let backend = ProbeBackend(loadDelay: .milliseconds(80))
  let core = runtime(backend)
  let first = try await core.generate(model: model, request: request())
  let cancelled = try await core.generate(model: model, request: request())
  let last = try await core.generate(model: model, request: request())
  try await Task.sleep(for: .milliseconds(20))
  cancelled.cancel()
  let events = await collect(cancelled)
  if case .finished(.cancelled) = events.last?.payload {
  } else {
    Issue.record("Expected cancelled waiter")
  }
  #expect(await core.snapshot().queued == 1)
  _ = await collect(first)
  _ = await collect(last)
  #expect(await backend.loads == 1)
  await core.shutdown()
}
@Test func byteLimitAndDynamicPressure() async throws {
  let output = GenerationHandle(requestID: UUID(), byteLimit: 8)
  #expect(!output.emit(.contentDelta("123456789")))
  output.finish(.finished(.stop))
  let events = await collect(output)
  if case .failed(let error) = events.last?.payload {
    #expect(error.code == .slowConsumer)
  } else {
    Issue.record("Expected byte overflow")
  }
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = RuntimeCoordinator(
    backend: ProbeBackend(), policy: .init(budgetBytes: 512 * 1024 * 1024), availableMemory: { 1 })
  let rejected = await collect(try await core.generate(model: model, request: request()))
  if case .failed(let error) = rejected.last?.payload {
    #expect(error.code == .resourceLimit)
  } else {
    Issue.record("Expected pressure rejection")
  }
  #expect(await core.snapshot().reservedBytes == 0)
}

@Test func cancellationWaitsForBackendBarrier() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(loadDelay: .zero, tokenDelay: .milliseconds(100), count: 100))
  let handle = try await core.generate(model: model, request: request())
  var cancelAt: ContinuousClock.Instant?
  for await event in handle.events {
    if case .contentDelta = event.payload, cancelAt == nil {
      cancelAt = .now
      handle.cancel()
      #expect(await core.snapshot().activeLeases == 1)
    }
  }
  await handle.waitUntilStopped()
  let start = try #require(cancelAt)
  #expect(start.duration(to: .now) >= .milliseconds(8))
  #expect(await core.snapshot().activeLeases == 0)
  await core.shutdown()
}

@Test func idleEvictionReclaimsReservation() async throws {
  let firstModel = try fixture()
  let secondModel = try fixture()
  defer {
    try? FileManager.default.removeItem(at: firstModel.directory)
    try? FileManager.default.removeItem(at: secondModel.directory)
  }
  let transient = firstModel.kvBytesPerToken * 8200 + firstModel.workspaceBytes
  let backend = ProbeBackend(loadDelay: .zero)
  let core = RuntimeCoordinator(
    backend: backend, policy: .init(budgetBytes: firstModel.weightBytes * 2 + transient))
  _ = await collect(try await core.generate(model: firstModel, request: request()))
  _ = await collect(try await core.generate(model: secondModel, request: request()))
  let snapshot = await core.snapshot()
  #expect(snapshot.residentModels == 1 && snapshot.reservedBytes == secondModel.weightBytes)
  try await core.unload(modelID: firstModel.id)
  #expect(await core.snapshot().residentModels == 1)
  #expect(await backend.loads == 2)
  await core.shutdown()
  #expect(await core.snapshot().reservedBytes == 0)
}

@Test func corruptWeightRejectedBeforeBackend() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try Data(repeating: 0, count: 32).write(
    to: model.directory.appendingPathComponent("model.safetensors"))
  #expect(throws: MoxError.self) { try LocalModel(path: model.directory.path) }
}

@Test func residentReferenceCannotSilentlySwitchAssets() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(loadDelay: .zero))
  _ = await collect(try await core.generate(model: model, request: request()))
  try Data("{\"changed\":true}".utf8).write(
    to: model.directory.appendingPathComponent("tokenizer_config.json"))
  let replacement = try LocalModel(path: model.directory.path)
  do {
    _ = try await core.generate(model: replacement, request: request())
    Issue.record("Changed reference reused resident weights")
  } catch let error as MoxError { #expect(error.code == .invalidModel) }
  try await core.unload(modelID: model.id)
  _ = await collect(try await core.generate(model: replacement, request: request()))
  await core.shutdown()
}

@Test func assetsChangedWhileLoadingRollBack() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(loadDelay: .milliseconds(80)))
  let handle = try await core.generate(model: model, request: request())
  try await Task.sleep(for: .milliseconds(20))
  try Data("{\"changed\":true}".utf8).write(
    to: model.directory.appendingPathComponent("tokenizer_config.json"))
  let events = await collect(handle)
  if case .failed(let error) = events.last?.payload {
    #expect(error.code == .invalidModel)
  } else {
    Issue.record("Changed loading assets were admitted")
  }
  #expect(await core.snapshot().reservedBytes == 0)
  #expect(await core.snapshot().residentModels == 0)
}

@Test func sequentialEventConsumptionAfterCancellationDrainsOneTerminal() async {
  let handle = GenerationHandle(requestID: UUID())
  #expect(handle.emit(.contentDelta("first")))
  var first = handle.events.makeAsyncIterator()
  #expect(await first.next()?.sequence == 0)
  handle.cancel()
  handle.finish(.finished(.stop))
  var remaining: [GenerationEvent] = []
  for await event in handle.events { remaining.append(event) }
  #expect(remaining.count == 1)
  if case .finished(.cancelled) = remaining.first?.payload {} else {
    Issue.record("Expected reserved cancellation terminal")
  }
  #expect(await first.next() == nil)
}

@Test func localReferenceMetadataCheckIncludesNamesAndHasNoContentHashGuarantee() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let tokenizer = model.directory.appendingPathComponent("tokenizer.json")
  // Whole-second fixture avoids Date-to-filesystem rounding differences; it also
  // represents a source with coarse timestamp resolution.
  let modified = Date(timeIntervalSince1970: 1_700_000_000)
  try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tokenizer.path)
  let reference = try LocalModel(path: model.directory.path)
  try Data("[]".utf8).write(to: tokenizer)
  try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tokenizer.path)
  // Referenced directories deliberately use metadata checks, not managed-artifact digests.
  try reference.validateUnchanged()
  try FileManager.default.moveItem(at: tokenizer, to: model.directory.appendingPathComponent("renamed.json"))
  #expect(throws: MoxError.self) { try reference.validateUnchanged() }
}

@Test func criticalPressureCleansResidentsAfterQueuedCancellation() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let core = runtime(ProbeBackend(loadDelay: .zero, tokenDelay: .milliseconds(10), count: 100))
  let active = try await core.generate(model: model, request: request())
  for await event in active.events {
    if case .contentDelta = event.payload { break }
  }
  var queued: [GenerationHandle] = []
  for _ in 0..<8 { queued.append(try await core.generate(model: model, request: request())) }
  let queuedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await core.snapshot().queued < queued.count, ContinuousClock.now < queuedDeadline { await Task.yield() }
  #expect(await core.snapshot().queued == queued.count)
  await core.updatePressure(.critical)
  await active.waitUntilStopped()
  for handle in queued { await handle.waitUntilStopped() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await core.snapshot().reservedBytes != 0, ContinuousClock.now < deadline { await Task.yield() }
  let state = await core.snapshot()
  #expect(state.activeLeases == 0)
  #expect(state.residentModels == 0)
  #expect(state.reservedBytes == 0)
  #expect(state.queued == 0)
  await core.shutdown()
}
