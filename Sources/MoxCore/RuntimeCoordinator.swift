import Foundation
import MoxDomain
import OSLog

public struct BackendResult: Sendable {
  public let reason: FinishReason
  public let usage: Usage?
  public init(reason: FinishReason, usage: Usage? = nil) {
    self.reason = reason
    self.usage = usage
  }
}
/// Implementations return only after all backend/GPU work has stopped.
public protocol LoadedModel: Sendable {
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  func unload() async
}
public protocol RuntimeBackend: Sendable {
  func load(_ model: LocalModel) async throws -> any LoadedModel
}
public struct RuntimePolicy: Sendable {
  public let budgetBytes: Int
  public let queueCapacity: Int
  public let queueTimeout: Duration
  public init(budgetBytes: Int, queueCapacity: Int = 8, queueTimeout: Duration = .seconds(60)) {
    self.budgetBytes = max(0, budgetBytes)
    self.queueCapacity = max(0, queueCapacity)
    self.queueTimeout = queueTimeout
  }
}
public struct RuntimeSnapshot: Sendable {
  public let residentModels: Int
  public let reservedBytes: Int
  public let activeLeases: Int
  public let queued: Int
}

public actor RuntimeCoordinator {
  private struct Slot {
    let model: LocalModel
    let loaded: any LoadedModel
    var tick: Int
  }
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
    let timer: Task<Void, Never>
  }
  private let backend: any RuntimeBackend
  private let policy: RuntimePolicy
  private let availableMemory: @Sendable () -> Int?
  private let logger = Logger(subsystem: "dev.mox", category: "runtime")
  private let signposter = OSSignposter(subsystem: "dev.mox", category: "runtime")
  private var slots: [String: Slot] = [:]
  private var loads: [String: Task<any LoadedModel, Error>] = [:]
  private var handleModels: [UUID: String] = [:]
  private var handles: [UUID: GenerationHandle] = [:]
  private var queue: [Waiter] = []
  private var occupied = false
  private var closing = false
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var reserved = 0
  private var leases = Set<UUID>()
  private var tick = 0
  public init(
    backend: any RuntimeBackend, policy: RuntimePolicy,
    availableMemory: @escaping @Sendable () -> Int? = { nil }
  ) {
    self.backend = backend
    self.policy = policy
    self.availableMemory = availableMemory
  }
  public func snapshot() -> RuntimeSnapshot {
    .init(
      residentModels: slots.count, reservedBytes: reserved, activeLeases: leases.count,
      queued: queue.count)
  }
  public func generate(model: LocalModel, request: GenerationRequest) throws -> GenerationHandle {
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    guard handles[request.id] == nil else {
      throw MoxError(.invalidParameters, "Request ID is already active.")
    }
    try model.validateUnchanged()
    try validateResidentReference(model)
    // Reserve a context-bounded KV allowance; exact token count is checked by the processor.
    let tokens = min(model.contextSize, 8192 + request.sampling.maxTokens)
    let transient = model.kvBytesPerToken * tokens + model.workspaceBytes
    guard model.weightBytes * 2 + transient <= policy.budgetBytes else {
      throw MoxError(
        .resourceLimit, "Model weights, load peak and KV/workspace exceed the safe memory budget.")
    }
    let handle = GenerationHandle(requestID: request.id)
    handles[request.id] = handle
    handleModels[request.id] = model.id
    handle.emit(.phase("accepted"))
    let task = Task {
      await self.run(model: model, request: request, transient: transient, handle: handle)
    }
    handle.own(task)
    return handle
  }
  private func run(
    model: LocalModel, request: GenerationRequest, transient: Int, handle: GenerationHandle
  ) async {
    let start = ContinuousClock.now
    var acquired = false
    var extra = 0
    var terminal: GenerationPayload
    var stage = BackendFailure.Stage.admission
    do {
      handle.emit(.phase("queued"))
      try await acquire(request.id)
      acquired = true
      try Task.checkCancellation()
      try model.validateUnchanged()
      try validateResidentReference(model)
      stage = .load
      if let load = loads[model.id], slots[model.id] == nil { _ = try await load.value }
      let needsLoad = slots[model.id] == nil
      let required = transient + (needsLoad ? model.weightBytes * 2 : 0)
      // Dynamic pressure may tighten the configured ceiling. Reclaim idle residents
      // before rejecting, and keep their reservation until backend unload returns.
      let headroom = availableMemory().map { Int(Double($0) * 0.8) }
      let ceiling = min(policy.budgetBytes, headroom.map { reserved + $0 } ?? policy.budgetBytes)
      while reserved + required > ceiling {
        guard
          let idle = slots.values.filter({ $0.model.id != model.id }).min(by: { $0.tick < $1.tick })
        else { throw MoxError(.resourceLimit, "No idle model can free enough memory.") }
        slots.removeValue(forKey: idle.model.id)
        await idle.loaded.unload()
        reserved -= idle.model.weightBytes
      }
      // The actor publishes the full reservation BEFORE loader/GPU suspension.
      extra = required
      reserved += extra
      if needsLoad {
        handle.emit(.phase("loading"))
        let interval = signposter.beginInterval("load")
        let began = ContinuousClock.now
        do {
          let loader = Task.detached { [backend] in try await backend.load(model) }
          loads[model.id] = loader
          let loaded = try await loader.value
          do { try model.validateUnchanged() } catch {
            await loaded.unload()
            let changed = MoxError(.invalidModel, "Referenced assets changed during loading.")
            loads[model.id] = Task { throw changed }
            throw changed
          }
          tick += 1
          slots[model.id] = Slot(model: model, loaded: loaded, tick: tick)
          loads.removeValue(forKey: model.id)
          extra -= model.weightBytes  // resident portion transfers to the slot
          logger.info(
            "model=\(model.id, privacy: .public) request=\(request.id.uuidString, privacy: .public) load_seconds=\(Self.seconds(began.duration(to: .now))) weights=\(model.weightBytes) transient=\(transient)"
          )
          signposter.endInterval("load", interval)
        } catch {
          signposter.endInterval("load", interval)
          throw error
        }
      }
      try Task.checkCancellation()
      guard let slot = slots[model.id] else {
        throw MoxError(.loadFailed, "Model load did not produce a handle.")
      }
      leases.insert(request.id)
      tick += 1
      slots[model.id]?.tick = tick
      handle.emit(.phase("prefill"))
      stage = .generate
      let result = try await slot.loaded.generate(request, output: handle)
      if let usage = result.usage {
        handle.emit(.usage(usage))
        logger.info(
          "model=\(model.id, privacy: .public) request=\(request.id.uuidString, privacy: .public) prefill_seconds=\(usage.prefillSeconds) decode_seconds=\(usage.decodeSeconds) prompt_tokens=\(usage.promptTokens) output_tokens=\(usage.outputTokens)"
        )
      }
      terminal = .finished(result.reason)
    } catch is CancellationError { terminal = .finished(.cancelled) } catch let failure
      as BackendFailure
    {
      failure.record(modelID: model.id, requestID: request.id)
      terminal = .failed(failure.clientError)
    } catch let error as MoxError {
      terminal = .failed(error)
    } catch {
      let failure = BackendFailure(error, stage: stage)
      failure.record(modelID: model.id, requestID: request.id)
      terminal = .failed(failure.clientError)
    }
    leases.remove(request.id)
    reserved -= extra
    if acquired { release() }
    handles.removeValue(forKey: request.id)
    handleModels.removeValue(forKey: request.id)
    if !handleModels.values.contains(model.id) { loads.removeValue(forKey: model.id) }
    logger.info(
      "model=\(model.id, privacy: .public) request=\(request.id.uuidString, privacy: .public) phase=\(handle.isCancelled ? "cancel" : "stopped", privacy: .public) elapsed_seconds=\(Self.seconds(start.duration(to: .now))) leases=\(self.leases.count)"
    )
    handle.finish(terminal)
    if let elapsed = handle.cancellationDuration {
      logger.info(
        "request=\(request.id.uuidString, privacy: .public) phase=cancel cancel_wait_seconds=\(Self.seconds(elapsed))"
      )
    }
  }
  private func validateResidentReference(_ model: LocalModel) throws {
    if let slot = slots[model.id], slot.model != model {
      throw MoxError(
        .invalidModel,
        "The resident model's directory changed; unload it before opening a new reference.")
    }
  }
  private func acquire(_ id: UUID) async throws {
    try Task.checkCancellation()
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    if !occupied {
      occupied = true
      return
    }
    guard queue.count < policy.queueCapacity else {
      throw MoxError(.queueFull, "GPU waiting queue is full.")
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timer = Task {
          do { try await Task.sleep(for: policy.queueTimeout) } catch { return }
          expire(id, error: MoxError(.queueTimeout, "GPU queue deadline exceeded."))
        }
        queue.append(Waiter(id: id, continuation: continuation, timer: timer))
      }
    } onCancel: {
      Task { await self.expire(id, error: CancellationError()) }
    }
  }
  private func expire(_ id: UUID, error: any Error) {
    guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
    let waiter = queue.remove(at: index)
    waiter.timer.cancel()
    waiter.continuation.resume(throwing: error)
  }
  private func release() {
    if queue.isEmpty {
      occupied = false
      let waiting = idleWaiters
      idleWaiters.removeAll()
      waiting.forEach { $0.resume() }
    } else {
      let waiter = queue.removeFirst()
      waiter.timer.cancel()
      waiter.continuation.resume()
    }
  }
  public func unload(modelID: String) async throws {
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    guard !occupied, handles.isEmpty else {
      throw MoxError(.busy, "Runtime has active or queued work.")
    }
    guard let slot = slots.removeValue(forKey: modelID) else { return }
    occupied = true
    await slot.loaded.unload()
    reserved -= slot.model.weightBytes
    release()
  }
  public func shutdown() async {
    closing = true
    let running = Array(handles.values)
    running.forEach { $0.cancel() }
    for handle in running { await handle.waitUntilStopped() }
    if occupied { await withCheckedContinuation { idleWaiters.append($0) } }
    for slot in slots.values { await slot.loaded.unload() }
    slots.removeAll()
    reserved = 0
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
