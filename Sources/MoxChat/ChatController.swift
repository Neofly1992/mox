import Foundation
import MoxBootstrap
import MoxClient
import MoxDomain
import MoxPersistence
import MoxProtocol
import Observation

public struct LiveReply: Sendable {
  public var isInProgress: Bool {
    ["pending", "streaming", "stopping"].contains(status)
  }
  public var attemptID: UUID
  public var conversationID: UUID
  public var requestID: UUID
  public var text = ""
  public var segments: [String] = []
  public var phase = "accepted"
  public var status = "pending"
  public var sequence = -1
  public var usage: Usage?
  public var error: MoxError?
  public var saved = true
  public var storageFailure: StorageFailure?
}

@MainActor @Observable public final class ChatController {
  public private(set) var conversations: [ConversationSummary] = []
  public private(set) var selected: ConversationSnapshot?
  public private(set) var conversationOffset = 0
  public private(set) var hasMoreConversations = false
  public private(set) var isLoadingHistory = false
  public private(set) var historyOffset = 0
  private var previousHistoryOffsets: [Int] = []
  private var selectionTask: Task<Void, Never>?
  private var historyReadID = UUID()
  private var summaryReadID = UUID()
  private var cachedSequences: [UUID: Int] = [:]
  private var lastOperationFailure: StorageFailure?
  private var lastErrorCode: MoxError.Code?
  public var replySegments: [UUID: [String]] = [:]
  public var selectedID: UUID?
  public var modelPath = ""
  public var draft = ""
  public var servicePhase = "disconnected"
  public var serviceState: ServiceState?
  public var live: LiveReply?
  public var error: String?
  public var storageAvailable = false
  public var maxTokens = Sampling.defaultMaxTokens
  public var temperature: Float = Sampling.defaultTemperature
  public var maxTokensExplicit = false
  public var temperatureExplicit = false
  public private(set) var effectiveSampling: EffectiveSampling?
  public private(set) var isWorking = false
  public private(set) var isClosing = false
  public private(set) var stopWaitIsLong = false
  public private(set) var connection: Connection?
  public let performance = PerformanceMetrics()
  public let root: String
  private let executable: URL
  private let openStore: @Sendable (URL) async throws -> any ConversationStoring
  private var store: (any ConversationStoring)?
  private var preparationCancelled = false
  private var sendID = UUID()
  public var isStopping: Bool { isWorking && (preparationCancelled || live?.status == "stopping") }
  public var canDeleteSelected: Bool {
    !isClosing && !isWorking && selectedID != nil
      && !(live?.conversationID == selectedID && live?.saved == false)
  }
  private var generation: RemoteGeneration?
  private var session: ChatRun?
  private var pendingFailureSave: LiveReply?
  private var epoch = UUID()
  private var ring = DiagnosticRing()
  private var monitor: Task<Void, Never>?
  public init(
    root: String, executable: URL,
    openStore: @escaping @Sendable (URL) async throws -> any ConversationStoring = {
      try await ConversationStore.open(root: $0)
    }
  ) {
    self.root = root
    self.executable = executable
    self.openStore = openStore
  }
  public func modelState(for path: String) -> String? {
    guard servicePhase == "running" else { return nil }
    let id = LocalModelIdentity.identifier(for: URL(fileURLWithPath: path))
    return serviceState?.models.first { $0.modelID == id }?.state ?? "unloaded"
  }
  public var ownerLabel: String {
    guard let connection else { return "未连接" }
    if connection.worker != nil { return "由此 App 启动" }
    return connection.client.discovery.identity.ownership == .externallyManaged
      ? "外部托管服务" : "已有外部服务"
  }
  public func selectModel(path: String) async {
    modelPath = path
    maxTokensExplicit = false
    temperatureExplicit = false
    await refreshEffectiveSampling()
  }
  public func setMaxTokensOverride(_ value: Int) {
    maxTokens = value
    maxTokensExplicit = true
    effectiveSampling = nil
  }
  public func setTemperatureOverride(_ value: Float) {
    temperature = value
    temperatureExplicit = true
    effectiveSampling = nil
  }
  public func refreshEffectiveSampling() async {
    guard let client = connection?.client, !modelPath.isEmpty else { return }
    do {
      let effective = try await client.resolveSampling(.init(
        model: .init(kind: "localDirectory", path: modelPath)))
      effectiveSampling = effective
      if !maxTokensExplicit { maxTokens = effective.maxTokens }
      if !temperatureExplicit { temperature = effective.temperature }
    } catch { show(error) }
  }
  public func start() async {
    BuildInfo.logStartup(component: "app")
    do {
      let files = try ServiceFiles(path: root)
      store = try await openStore(files.root)
      storageAvailable = true
      try await reload()
      select(conversations.first?.id)
      await selectionTask?.value
    } catch {
      show(error)
      return
    }
    await connect()
  }
  public func connect() async {
    guard !isWorking, !isClosing, servicePhase != "connecting" else { return }
    let nextEpoch = UUID()
    epoch = nextEpoch
    servicePhase = "connecting"
    do {
      var value = try await Connection.open(root: root, executable: executable)
      guard epoch == nextEpoch else {
        value.worker?.requestStop()
        return
      }
      if let previous = connection,
        previous.client.discovery.identity == value.client.discovery.identity
      {
        value = previous
      }
      let state = try await value.client.state()
      guard epoch == nextEpoch else {
        value.worker?.requestStop()
        return
      }
      connection = value
      serviceState = state
      servicePhase = "running"
      error = nil
      if !modelPath.isEmpty { await refreshEffectiveSampling() }
      ring.record(
        .init(
          stage: "connection", code: "running",
          instanceID: value.client.discovery.identity.instanceID))
      monitor?.cancel()
      monitor = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: ChatPolicy.servicePoll)
          guard let self, self.epoch == nextEpoch, !Task.isCancelled else { return }
          do {
            let state = try await value.client.state()
            guard self.epoch == nextEpoch, !Task.isCancelled else { return }
            self.serviceState = state
          } catch {
            guard self.epoch == nextEpoch, !Task.isCancelled else { return }
            self.servicePhase = "unavailable"
            self.show(error)
            if !self.isWorking { await self.reconnectAfterLoss() }
            return
          }
        }
      }
    } catch {
      if epoch == nextEpoch {
        servicePhase = "unavailable"
        show(error)
      }
    }
  }
  public func newConversation() async {
    guard !isClosing, let store else { return }
    do {
      let id = try await store.create(modelPath: modelPath)
      conversationOffset = 0
      select(id)
      try await reload()
    } catch { show(error) }
  }
  public func select(_ id: UUID?) {
    selectionTask?.cancel()
    historyReadID = UUID()
    selectedID = id
    selected = nil
    historyOffset = 0
    previousHistoryOffsets = []
    replySegments = [:]
    cachedSequences = [:]
    if let summary = conversations.first(where: { $0.id == id }) { modelPath = summary.modelPath }
    selectionTask = Task { [weak self] in
      guard let self else { return }
      do { try await self.loadSelectedHistory(offset: 0) } catch { self.show(error) }
    }
  }
  public func changeConversationPage(older: Bool) async {
    let offset = max(
      0, conversationOffset + (older ? HistoryLimit.conversations : -HistoryLimit.conversations))
    do { try await loadSummaries(offset: offset) } catch { show(error) }
  }
  public func changeHistoryPage(older: Bool) async {
    guard !isLoadingHistory, let selected else { return }
    let offset: Int
    if older {
      guard selected.hasMore else { return }
      offset = historyOffset + selected.attempts.count
    } else {
      guard let previous = previousHistoryOffsets.last else { return }
      offset = previous
    }
    let previousOffset = historyOffset
    let id = selected.id
    do {
      try await loadSelectedHistory(offset: offset)
      guard selectedID == id, historyOffset == offset else { return }
      if older {
        previousHistoryOffsets.append(previousOffset)
      } else {
        previousHistoryOffsets.removeLast()
      }
    } catch { show(error) }
  }
  public func deleteSelected() async {
    guard canDeleteSelected, let store, let selectedID else { return }
    do {
      try await store.delete(selectedID)
      select(nil)
      try await reload()
    } catch { show(error) }
  }
  public func selectBranch(_ attemptID: UUID) async {
    guard !isClosing, let store, let selectedID, !isWorking else { return }
    do {
      try await store.selectLeaf(conversationID: selectedID, attemptID: attemptID)
      try await reload()
    } catch { show(error) }
  }
  public func send(retryOf: UUID? = nil) async {
    guard !isWorking, !isClosing, live?.saved != false, storageAvailable, let store, let connection,
      servicePhase == "running", !modelPath.isEmpty,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || retryOf != nil
    else { return }
    isWorking = true
    preparationCancelled = false
    sendID = UUID()
    session = nil
    generation = nil
    let targetID = selectedID
    let prompt = draft
    let path = modelPath
    let explicit = SamplingSettings(
      maxTokens: maxTokensExplicit ? maxTokens : nil,
      temperature: temperatureExplicit ? temperature : nil)
    stopWaitIsLong = false
    error = nil
    let currentEpoch = epoch
    var unstarted: PendingAttempt?
    var unstartedConversationID: UUID?
    do {
      let effective = try await connection.client.resolveSampling(.init(
        model: .init(kind: "localDirectory", path: path), explicit: explicit))
      effectiveSampling = effective
      if !maxTokensExplicit { maxTokens = effective.maxTokens }
      if !temperatureExplicit { temperature = effective.temperature }
      let sampling = try effective.sampling()
      let cid: UUID
      if let targetID {
        cid = targetID
      } else {
        cid = try await store.create(modelPath: path)
        if selectedID == nil { selectedID = cid }
      }
      let pending = try await store.begin(
        conversationID: cid, prompt: prompt, modelPath: path,
        sampling: sampling, retryOf: retryOf)
      unstarted = pending
      unstartedConversationID = cid
      if retryOf == nil, draft == prompt { draft = "" }
      historyOffset = 0
      previousHistoryOffsets = []
      try await reload()
      if preparationCancelled {
        await finishUnstarted(pending, conversationID: cid, status: "cancelled", error: nil)
        isWorking = false
        return
      }
      let request = pending.request
      let remote = try connection.client.generate(path: pending.modelPath, request: request)
      generation = remote
      let initial = LiveReply(
        attemptID: pending.attemptID, conversationID: cid, requestID: request.id)
      live = initial
      let run = ChatRun(
        initial: initial, remote: remote, store: store, performance: performance,
        instanceID: connection.client.discovery.identity.instanceID
      ) { [weak self] value in
        await MainActor.run {
          guard let self, self.epoch == currentEpoch, self.live?.requestID == value.requestID else {
            return
          }
          if self.live?.phase != value.phase || self.live?.status != value.status {
            self.ring.record(
              .init(
                stage: value.phase, code: value.error?.code.rawValue ?? value.status,
                instanceID: self.connection?.client.discovery.identity.instanceID,
                requestID: value.requestID))
          }
          var visible = value
          if self.live?.status == "stopping", ["pending", "streaming"].contains(visible.status) {
            visible.status = "stopping"
          }
          if let failure = visible.storageFailure, failure != self.live?.storageFailure {
            self.show(failure)
          }
          self.live = visible
        }
      }
      session = run
      unstarted = nil
      Task { [weak self] in
        await run.execute()
        guard let self, self.epoch == currentEpoch else { return }
        self.isWorking = false
        self.generation = nil
        do { try await self.reload() } catch { self.show(error) }
        if self.live?.error?.code == .connectionLost { await self.reconnectAfterLoss() }
      }
    } catch {
      show(error)
      if let pending = unstarted, let cid = unstartedConversationID {
        let failure = (error as? MoxError) ?? MoxError(.connectionLost, "Request could not start.")
        await finishUnstarted(pending, conversationID: cid, status: "failed", error: failure)
      }
      isWorking = false
    }
  }
  private func finishUnstarted(
    _ pending: PendingAttempt, conversationID: UUID, status: String, error: MoxError?
  ) async {
    var reply = LiveReply(
      attemptID: pending.attemptID, conversationID: conversationID,
      requestID: pending.request.id)
    reply.status = status
    reply.error = error
    do {
      try await store?.checkpoint(reply)
      try await reload()
    } catch {
      reply.saved = false
      pendingFailureSave = reply
      show(error)
    }
    live = reply
  }
  public func stop() {
    guard isWorking else { return }
    let stoppedSend = sendID
    preparationCancelled = true
    if generation != nil { live?.status = "stopping" }
    generation?.cancel()
    if let session { Task { await session.stop() } }
    Task { [weak self] in
      try? await Task.sleep(for: ChatPolicy.longStopNotice)
      guard let self, self.isWorking, self.sendID == stoppedSend, self.isStopping
      else { return }
      self.stopWaitIsLong = true
    }
  }
  public func retrySave() async {
    if var failed = pendingFailureSave, let store {
      do {
        try await store.checkpoint(failed)
        failed.saved = true
        live = failed
        pendingFailureSave = nil
        try await reload()
      } catch { show(error) }
      return
    }
    guard let session else { return }
    await session.retrySave()
    do { try await reload() } catch { show(error) }
  }
  private func reconnectAfterLoss() async {
    let reconnectEpoch = epoch
    servicePhase = "reconnecting"
    let files: ServiceFiles
    do { files = try ServiceFiles(path: root) } catch {
      show(error)
      servicePhase = "unavailable"
      return
    }
    for delay in ChatPolicy.reconnectDelays {
      try? await Task.sleep(for: delay)
      guard epoch == reconnectEpoch, !Task.isCancelled, !isClosing else { return }
      do {
        if let d = try files.read() {
          let client = ServiceClient(discovery: d)
          _ = try await client.identity()
          guard epoch == reconnectEpoch, !Task.isCancelled, !isClosing else { return }
          if d.identity.instanceID == connection?.client.discovery.identity.instanceID,
            let requestID = live?.requestID
          {
            if let state = try? await client.requestState(requestID), state.terminal == nil {
              _ = try await client.cancel(requestID)
              continue
            }
          }
          await connect()
          return
        }
      } catch {}
    }
    if epoch == reconnectEpoch { servicePhase = "unavailable" }
  }
  public func shutdown() async -> Bool {
    monitor?.cancel()
    stop()
    let deadline = ContinuousClock.now.advanced(by: .seconds(ServiceTiming.shutdownSeconds))
    while isWorking && ContinuousClock.now < deadline {
      try? await Task.sleep(for: ChatPolicy.refresh)
    }
    guard !isWorking, live?.saved != false else { return false }
    if let worker = connection?.worker {
      worker.requestStop()
      return await worker.wait()
    }
    return true
  }
  public func prepareToQuit() async -> Bool {
    isClosing = true
    if isWorking { return true }
    guard let connection, connection.worker != nil else { return false }
    do {
      let state = try await connection.client.state()
      serviceState = state
      if !state.requests.isEmpty { return true }
      return state.activeDownloads > 0
    } catch {
      show(error)
      return true
    }
  }
  public func cancelQuit() { isClosing = false }
  public func forceShutdown() async {
    generation?.disconnect()
    if let worker = connection?.worker { await worker.forceStop() }
  }
  private func reload() async throws {
    try await loadSummaries(offset: conversationOffset)
    try await loadSelectedHistory(offset: historyOffset)
  }
  private func loadSummaries(offset: Int) async throws {
    guard let store else { return }
    let readID = UUID()
    summaryReadID = readID
    let page = try await store.list(offset: offset)
    guard summaryReadID == readID else { return }
    conversations = page.items
    conversationOffset = page.offset
    hasMoreConversations = page.hasMore
  }
  private func loadSelectedHistory(offset: Int) async throws {
    let readID = UUID()
    historyReadID = readID
    guard let store, let id = selectedID else {
      selected = nil
      replySegments = [:]
      cachedSequences = [:]
      isLoadingHistory = false
      return
    }
    isLoadingHistory = true
    defer { if historyReadID == readID { isLoadingHistory = false } }
    let snapshot: ConversationSnapshot
    do { snapshot = try await store.detail(id, offset: offset) } catch {
      guard historyReadID == readID, selectedID == id, !Task.isCancelled else { return }
      throw error
    }
    guard historyReadID == readID, selectedID == id, !Task.isCancelled else { return }
    let cached = replySegments
    let sequences = cachedSequences
    let current = live
    let segments = await Task.detached {
      Dictionary(
        uniqueKeysWithValues: snapshot.attempts.map { attempt in
          let chunks: [String]
          if let current, current.attemptID == attempt.id {
            chunks = current.segments
          } else if sequences[attempt.id] == attempt.lastSequence, let existing = cached[attempt.id]
          {
            chunks = existing
          } else {
            chunks = TextSegments(attempt.reply).values
          }
          return (attempt.id, chunks)
        })
    }.value
    guard historyReadID == readID, selectedID == id, !Task.isCancelled else { return }
    selected = snapshot
    historyOffset = offset
    replySegments = segments
    cachedSequences = Dictionary(
      uniqueKeysWithValues: snapshot.attempts.map { ($0.id, $0.lastSequence) })
  }
  private func show(_ error: Error) {
    if let failure = error as? StorageFailure {
      lastOperationFailure = failure
      lastErrorCode = failure.code
      ring.record(.init(stage: "storage.\(failure.stage.rawValue)", code: failure.code.rawValue))
      self.error = failure.userError.description
    } else {
      let code = (error as? MoxError)?.code ?? .storageFailed
      lastErrorCode = code
      ring.record(.init(stage: "app", code: code.rawValue))
      self.error = (error as? MoxError)?.description ?? "storageFailed: 无法打开或保存对话。原数据已保留，请检查诊断。"
    }
  }
  public func recordOperationFailure(_ failure: Error, stage: String, operationID: UUID? = nil) {
    let code = (failure as? MoxError)?.code.rawValue ?? "operationFailed"
    let underlying = failure as NSError
    ring.record(.init(stage: stage, code: code,
      instanceID: connection?.client.discovery.identity.instanceID, operationID: operationID,
      systemDomain: failure is MoxError ? nil : underlying.domain,
      systemCode: failure is MoxError ? nil : underlying.code))
  }
  public func diagnostics() async throws -> Data {
    struct Report: Encodable {
      let configuration: String
      let buildID: String
      let instanceID: UUID?
      let requestID: UUID?
      let servicePhase: String
      let phase: String?
      let errorCode: String?
      let operationFailure: StorageFailure?
      let saved: Bool?
      let effectiveSampling: EffectiveSampling?
      let runtimeBudgetBytes: Int?
      let runtimeQueueCapacity: Int?
      let runtimeQueueTimeoutSeconds: Int?
      let events: [DiagnosticEvent]
      let serviceEvents: [DiagnosticEvent]
      let serviceDiagnosticsStatus: String
      let workerOutput: WorkerOutputSnapshot?
    }
    let serviceEvents: [DiagnosticEvent]
    let diagnosticsStatus: String
    if let client = connection?.client {
      do { serviceEvents = try await client.diagnosticEvents(); diagnosticsStatus = "available" }
      catch {
        serviceEvents = []; diagnosticsStatus = "unavailable"
        self.error = "服务诊断不可取得；已保留本机诊断，恢复连接后可重新导出。"
      }
    } else { serviceEvents = []; diagnosticsStatus = "disconnected" }
    return try Wire.encode(
      Report(
        configuration: BuildInfo.configuration, buildID: Wire.buildID,
        instanceID: connection?.client.discovery.identity.instanceID,
        requestID: live?.requestID, servicePhase: servicePhase, phase: live?.phase,
        errorCode: lastErrorCode?.rawValue ?? live?.error?.code.rawValue,
        operationFailure: lastOperationFailure, saved: live?.saved,
        effectiveSampling: effectiveSampling,
        runtimeBudgetBytes: serviceState?.budgetBytes,
        runtimeQueueCapacity: serviceState?.queueCapacity,
        runtimeQueueTimeoutSeconds: serviceState?.queueTimeoutSeconds,
        events: ring.events,
        serviceEvents: serviceEvents, serviceDiagnosticsStatus: diagnosticsStatus,
        workerOutput: connection?.worker?.outputSnapshot))
  }
}

private actor ChatRun {
  var value: LiveReply
  let remote: RemoteGeneration
  let store: any ConversationStoring
  let performance: PerformanceMetrics
  let instanceID: UUID
  let update: @Sendable (LiveReply) async -> Void
  var lastSave = ContinuousClock.now
  var lastBytes = 0
  var saving = false
  var saveFailed = false
  var done = false
  var document = TextSegments()
  init(
    initial: LiveReply, remote: RemoteGeneration, store: any ConversationStoring,
    performance: PerformanceMetrics, instanceID: UUID,
    update: @escaping @Sendable (LiveReply) async -> Void
  ) {
    value = initial
    self.remote = remote
    self.store = store
    self.performance = performance
    self.instanceID = instanceID
    self.update = update
  }
  func stop() {
    guard !done else { return }
    value.status = "stopping"
    remote.cancel()
  }
  func execute() async {
    let ticker = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: ChatPolicy.refresh)
        if !Task.isCancelled { await tick() }
      }
    }
    do {
      var terminalStatus: String?
      for try await event in remote.events {
        value.sequence = event.sequence
        switch event.payload {
        case .phase(let phase):
          value.phase = phase
          if value.status != "stopping" { value.status = "streaming" }
        case .contentDelta(let text):
          value.text += text
          document.append(text)
          value.segments = document.values
        case .promptTokens, .toolCall, .matchedStopSequence: break
        case .usage(let usage): value.usage = usage
        case .finished(let reason): terminalStatus = reason.rawValue
        case .failed(let error):
          terminalStatus = "failed"
          value.error = error
        }
        if value.text.utf8.count - lastBytes >= ChatPolicy.checkpointBytes { await persist() }
      }
      // EOF validation must succeed before a reply becomes eligible for context.
      value.status = terminalStatus ?? "interrupted"
    } catch {
      value.status = remote.wasRejected ? "failed" : "interrupted"
      value.error =
        (error as? MoxError)
        ?? MoxError(.connectionLost, "Connection lost; partial reply preserved.")
      remote.cancel()
    }
    if !(await remote.waitUntilStopped()) {
      value.status = "interrupted"
      value.error = MoxError(.connectionLost, "尚未确认模型停止；请重新连接核对服务状态。")
    }
    done = true
    ticker.cancel()
    while saving { try? await Task.sleep(for: ChatPolicy.saveBarrierPoll) }
    await persist()
    await update(value)
  }
  private func tick() async {
    if !done { await update(value) }
    if lastSave.duration(to: .now) >= ChatPolicy.checkpointInterval { await persist() }
  }
  private func persist() async {
    guard !saving, !saveFailed else { return }
    saving = true
    let snapshot = value
    let began = ProcessInfo.processInfo.systemUptime
    defer { performance.record(.checkpoint, seconds: ProcessInfo.processInfo.systemUptime - began) }
    do {
      try await store.checkpoint(snapshot, instanceID: instanceID)
      value.saved = true
      value.storageFailure = nil
      lastBytes = snapshot.text.utf8.count
      lastSave = .now
    } catch {
      value.saved = false
      value.storageFailure = StorageFailure.capture(error, stage: .save)
      saveFailed = true
      remote.cancel()
    }
    saving = false
  }
  func retrySave() async {
    saveFailed = false
    await persist()
    if value.saved, value.error?.code == .storageFailed { value.error = nil }
    await update(value)
  }
}

extension ConversationStoring {
  fileprivate func checkpoint(_ reply: LiveReply, instanceID: UUID? = nil) async throws {
    try await checkpoint(
      attemptID: reply.attemptID, instanceID: instanceID, text: reply.text, status: reply.status,
      sequence: reply.sequence, usage: reply.usage, errorCode: reply.error?.code.rawValue)
  }
}
