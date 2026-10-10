import Foundation
import MoxDomain
import OSLog

public struct BackendResult: Sendable {
  public let reason: FinishReason
  public let usage: Usage?
  public let matchedStopSequence: String?
  public init(reason: FinishReason, usage: Usage? = nil, matchedStopSequence: String? = nil) {
    self.reason = reason
    self.usage = usage
    self.matchedStopSequence = matchedStopSequence
  }
}
/// Implementations return only after all backend/GPU work has stopped.
public protocol LoadedModel: Sendable {
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  func unload() async
}
public protocol RuntimeBackend: Sendable {
  /// Native backends can tighten policy to their configured/device ceiling.
  var memoryBudgetCeilingBytes: Int? { get }
  func load(_ model: LocalModel) async throws -> any LoadedModel
  func memorySnapshot() -> BackendMemorySnapshot?
}
extension RuntimeBackend {
  public var memoryBudgetCeilingBytes: Int? { nil }
  public func memorySnapshot() -> BackendMemorySnapshot? { nil }
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
  public let pressure: MemoryPressureLevel
  public let admissionPaused: Bool
  public let backendMemory: BackendMemorySnapshot?
  public let residentModels: Int
  public let reservedBytes: Int
  public let activeLeases: Int
  public let queued: Int
  public let budgetBytes: Int
  public let queueCapacity: Int
  public let queueTimeoutSeconds: Int
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
  private var pressure: MemoryPressureLevel = .normal
  private var recoveryTask: Task<Void, Never>?
  private var pressureTrimTask: Task<Void, Never>?
  private var pressureEpoch = 0
  private static let availablePageHeadroomFraction = 0.8
  private static let pressureRecoveryDelay: Duration = .seconds(5)
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var reserved = 0
  private var leases = Set<UUID>()
  private var pinnedModelIDs = Set<String>()
  private var tick = 0
  public init(
    backend: any RuntimeBackend, policy: RuntimePolicy,
    availableMemory: @escaping @Sendable () -> Int? = { nil }
  ) {
    self.backend = backend
    self.policy = RuntimePolicy(
      budgetBytes: min(policy.budgetBytes, backend.memoryBudgetCeilingBytes ?? policy.budgetBytes),
      queueCapacity: policy.queueCapacity, queueTimeout: policy.queueTimeout)
    self.availableMemory = availableMemory
  }
  public func modelStates() -> [(id: String, state: String)] {
    let ids = Set(slots.keys).union(loads.keys)
    return ids.sorted().map { ($0, slots[$0] == nil ? "loading" : "ready") }
  }
  public func resourceBudgetBytes() -> Int { policy.budgetBytes }
  public func snapshot() -> RuntimeSnapshot {
    .init(
      pressure: pressure, admissionPaused: pressure != .normal,
      backendMemory: backend.memorySnapshot(),
      residentModels: slots.count, reservedBytes: reserved, activeLeases: leases.count,
      queued: queue.count, budgetBytes: policy.budgetBytes,
      queueCapacity: policy.queueCapacity,
      queueTimeoutSeconds: Int(policy.queueTimeout.components.seconds))
  }
  /// Platform signals enter the same authority as all request admission.
  public func updatePressure(_ level: MemoryPressureLevel) {
    pressureEpoch += 1
    recoveryTask?.cancel()
    if level == .normal {
      guard pressure != .normal else { return }
      let epoch = pressureEpoch
      recoveryTask = Task {
        do { try await Task.sleep(for: Self.pressureRecoveryDelay) } catch { return }
        if epoch == pressureEpoch { pressure = .normal }
      }
      return
    }
    pressure = level
    schedulePressureTrim()
    logger.warning("phase=memory-pressure level=\(level.rawValue, privacy: .public)")
    if level == .critical {
      // cancel() requests stop; reservations remain until the existing backend barrier.
      handles.values.forEach { $0.cancel() }
      for id in queue.map(\.id) {
        expire(
          id, error: MoxError(.resourceLimit, "Critical memory pressure; retry after recovery."))
      }
    }
  }
  private func schedulePressureTrim() {
    guard pressure != .normal, pressureTrimTask == nil else { return }
    pressureTrimTask = Task { await self.trimIdleForPressure() }
  }
  private func trimIdleForPressure() async {
    defer { pressureTrimTask = nil }
    guard !occupied, !closing, pressure != .normal else { return }
    occupied = true
    await trimPressureResidents()
    release()
  }
  /// Caller owns the GPU gate. Fixed residents survive pressure; freed reservations
  /// reflect completed backend unload, never a cancellation request.
  private func trimPressureResidents() async {
    while pressure != .normal,
      let slot = slots.values.filter({
        !pinnedModelIDs.contains($0.model.id)
          && !handleModels.values.contains($0.model.id)
      }).min(by: { $0.tick < $1.tick })
    {
      slots.removeValue(forKey: slot.model.id)
      await slot.loaded.unload()
      reserved -= slot.model.weightBytes
    }
  }
  private func checkAdmissionState() throws {
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    guard pressure == .normal else {
      throw MoxError(
        .resourceLimit,
        "Memory pressure \(pressure.rawValue); new work paused. Retry after 5 seconds of normal pressure."
      )
    }
  }
  public func assess(model: LocalModel, maxTokens: Int) -> ResourceAssessment {
    let headroom = availableMemory().map {
      Int(Double(max(0, $0)) * Self.availablePageHeadroomFraction)
    }
    let currentReservation = min(reserved, policy.budgetBytes)
    let remainingBudget = policy.budgetBytes - currentReservation
    let dynamicCeiling = currentReservation + min(remainingBudget, headroom ?? remainingBudget)
    let ceiling = pressure == .normal ? dynamicCeiling : 0
    return model.resources.assessment(
      maxTokens: maxTokens, budgetBytes: ceiling,
      residentBytes: reserved, alreadyResident: slots[model.id] != nil, admissionPressure: pressure)
  }
  public func setPinned(modelID: String, _ pinned: Bool) {
    if pinned { pinnedModelIDs.insert(modelID) }
    else { pinnedModelIDs.remove(modelID) }
  }
  public func generate(model: LocalModel, request: GenerationRequest) throws -> GenerationHandle {
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    guard handles[request.id] == nil else {
      throw MoxError(.invalidParameters, "Request ID is already active.")
    }
    try checkAdmissionState()
    try model.validateUnchanged()
    try validateResidentReference(model)
    guard request.sampling.maxTokens < model.contextSize else {
      throw MoxError(
        .contextLimit, "Requested output leaves no room for input; reduce maxTokens explicitly.")
    }
    // Reserve a context-bounded KV allowance; exact token count is checked by the processor.
    let estimate = model.resources.assessment(
      maxTokens: request.sampling.maxTokens,
      budgetBytes: policy.budgetBytes, alreadyResident: slots[model.id] != nil)
    guard let kv = estimate.kvBytes, let workspace = estimate.workspaceBytes,
      estimate.status != .exceedsBudget, estimate.status != .unknown
    else {
      throw MoxError(.resourceLimit, estimate.summary)
    }
    let transient = kv + workspace
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
      try checkAdmissionState()
      try Task.checkCancellation()
      try model.validateUnchanged()
      try validateResidentReference(model)
      stage = .load
      if let load = loads[model.id], slots[model.id] == nil { _ = try await load.value }
      let needsLoad = slots[model.id] == nil
      let required = transient + (needsLoad ? model.weightBytes * 2 : 0)
      // Dynamic pressure may tighten the configured ceiling. Reclaim idle residents
      // before rejecting, and keep their reservation until backend unload returns.
      try await reclaimCapacity(required: required, excluding: model.id)
      // The actor publishes the full reservation BEFORE loader/GPU suspension.
      extra = required
      reserved += extra
      if needsLoad {
        handle.emit(.phase("loading"))
        try await loadIntoSlot(model, requestID: request.id, transient: transient)
        extra -= model.weightBytes
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
      if let sequence = result.matchedStopSequence { handle.emit(.matchedStopSequence(sequence)) }
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
    handles.removeValue(forKey: request.id)
    handleModels.removeValue(forKey: request.id)
    if !handleModels.values.contains(model.id) { loads.removeValue(forKey: model.id) }
    if acquired {
      await trimPressureResidents()
      release()
    } else {
      // A cancelled waiter can remove the last reference after the active owner
      // already trimmed. Revisit idle residents through the same GPU gate.
      schedulePressureTrim()
    }
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
  /// Explicit load and generation use the same admission and backend transition.
  public func load(model: LocalModel) async throws {
    guard !closing else { throw MoxError(.shuttingDown, "Runtime is shutting down.") }
    try model.validateUnchanged()
    try validateResidentReference(model)
    try checkAdmissionState()
    if slots[model.id] != nil { return }
    // Explicit load includes the adapter's one-token warmup, not just weight IO.
    let warmup = model.resources.assessment(maxTokens: 1, budgetBytes: policy.budgetBytes)
    guard let required = warmup.peakBytes, let kv = warmup.kvBytes,
      let workspace = warmup.workspaceBytes, warmup.status != .exceedsBudget else {
      throw MoxError(.resourceLimit, warmup.summary)
    }
    let transient = kv + workspace
    let id = UUID()
    try await acquire(id)
    var extra = 0
    do {
      try Task.checkCancellation()
      try checkAdmissionState()
      if slots[model.id] == nil {
        try await reclaimCapacity(required: required, excluding: model.id)
        extra = required
        reserved += extra
        try await loadIntoSlot(model, requestID: id, transient: transient)
        extra -= model.weightBytes
      }
      reserved -= extra
      extra = 0
      await trimPressureResidents()
      try checkAdmissionState()
      release()
    } catch {
      reserved -= extra
      loads.removeValue(forKey: model.id)
      await trimPressureResidents()
      release()
      throw error
    }
  }
  private func reclaimCapacity(required: Int, excluding modelID: String) async throws {
    while true {
      try Task.checkCancellation()
      try checkAdmissionState()
      // VM free+inactive is advisory reclaimable pages, not total process allocation
      // capacity. Re-sample after each confirmed unload; normal pressure is no exemption.
      let headroom = availableMemory().map {
        Int(Double(max(0, $0)) * Self.availablePageHeadroomFraction)
      }
      if required <= policy.budgetBytes - reserved,
        headroom.map({ required <= $0 }) ?? true
      {
        return
      }
      guard
        let idle = slots.values.filter({
          $0.model.id != modelID && !pinnedModelIDs.contains($0.model.id)
            && !handleModels.values.contains($0.model.id)
        }).min(by: { $0.tick < $1.tick })
      else {
        throw MoxError(
          .resourceLimit,
          "No idle unpinned model can free enough memory. Choose smaller weights or output allowance, or explicitly unload fixed models when idle."
        )
      }
      slots.removeValue(forKey: idle.model.id)
      await idle.loaded.unload()
      reserved -= idle.model.weightBytes
    }
  }
  private func loadIntoSlot(_ model: LocalModel, requestID: UUID, transient: Int) async throws {
    if let load = loads[model.id], slots[model.id] == nil { _ = try await load.value }
    guard slots[model.id] == nil else { return }
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
      logger.info(
        "model=\(model.id, privacy: .public) request=\(requestID.uuidString, privacy: .public) load_seconds=\(Self.seconds(began.duration(to: .now))) weights=\(model.weightBytes) transient=\(transient)"
      )
      signposter.endInterval("load", interval)
    } catch {
      if !handleModels.values.contains(model.id) { loads.removeValue(forKey: model.id) }
      signposter.endInterval("load", interval)
      throw error
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
    await trimPressureResidents()
    release()
  }
  public func shutdown() async {
    closing = true
    recoveryTask?.cancel()
    let running = Array(handles.values)
    running.forEach { $0.cancel() }
    for handle in running { await handle.waitUntilStopped() }
    await pressureTrimTask?.value
    if occupied { await withCheckedContinuation { idleWaiters.append($0) } }
    for slot in slots.values { await slot.loaded.unload() }
    slots.removeAll()
    reserved = 0
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
