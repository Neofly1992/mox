import Foundation
import MoxDomain
import MoxProtocol

public final class ServiceClient: Sendable {
  public let discovery: Discovery
  public init(discovery: Discovery) { self.discovery = discovery }
  public func request(_ path: String, method: String = "GET", body: Data? = nil) throws
    -> URLRequest
  {
    guard let base = URLComponents(string: discovery.privateEndpoint), base.scheme == "http",
      base.host == "127.0.0.1", base.port != nil, base.user == nil, base.password == nil,
      base.query == nil, base.fragment == nil, base.path.isEmpty,
      let url = URL(string: discovery.privateEndpoint + "/mox/v1" + path)
    else { throw MoxError(.protocolViolation, "Unsafe service endpoint.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(discovery.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if path.contains("/cancel") {
      request.timeoutInterval = ServiceTiming.cancellationRequestTimeout
    } else if path == "/downloads" || path == "/downloads/plan" || path == "/doctor/inspect" || path.hasSuffix("/load") {
      request.timeoutInterval = ServiceTiming.managementWorkTimeout
    } else { request.timeoutInterval = ServiceTiming.requestTimeout }
    return request
  }
  public func identity() async throws -> ServiceIdentity {
    let value: ServiceIdentity = try await json("/identity")
    guard value == discovery.identity, value.buildID == Wire.buildID,
      value.protocolVersion == Wire.version
    else { throw MoxError(.incompatibleService, "Service identity or version does not match.") }
    return value
  }
  public func state() async throws -> ServiceState { try await json("/state") }
  public func diagnosticEvents() async throws -> [DiagnosticEvent] { try await json("/diagnostics") }
  public func publicAPIStatus() async throws -> PublicAPIStatus { try await json("/public-api") }
  public func setPublicAPIEnabled(_ enabled: Bool) async throws -> PublicAPIStatus {
    try await json("/public-api", method: "POST", body: Wire.encode(PublicAPIChange(enabled: enabled)))
  }
  public func publicAPIKey() async throws -> PublicAPIKey { try await json("/public-api/key") }
  public func rotatePublicAPIKey() async throws -> PublicAPIKey {
    try await json("/public-api/rotate", method: "POST")
  }
  public func cancel(_ id: UUID) async throws -> RequestState {
    try await json("/generations/\(id)/cancel", method: "POST")
  }
  public func requestState(_ id: UUID) async throws -> RequestState {
    try await json("/generations/\(id)")
  }
  public func generate(path: String, request: GenerationRequest) throws -> RemoteGeneration {
    try generate(model: .init(kind: "localDirectory", path: path), request: request)
  }
  public func generate(model: GenerateBody.Model, request: GenerationRequest) throws -> RemoteGeneration {
    let body = try Wire.encode(GenerateBody(model: model, request: request))
    return RemoteGeneration(
      client: self, requestID: request.id,
      request: try self.request("/generations", method: "POST", body: body))
  }
  public func setDefaultRegistry(_ update: DefaultRegistryUpdate) async throws -> ModelConfiguration {
    try await json("/config/default", method: "POST", body: Wire.encode(update))
  }
  public func inspectModel(_ model: GenerateBody.Model) async throws -> DoctorResult {
    try await inspectForDoctor(.init(model: model))
  }
  public func inspectSource(_ source: PullBody) async throws -> DoctorResult {
    try await inspectForDoctor(.init(source: source))
  }
  private func inspectForDoctor(_ body: DoctorInspectionBody) async throws -> DoctorResult {
    do {
      let result: DoctorResult = try await withTaskCancellationHandler {
        try await json("/doctor/inspect", method: "POST", body: Wire.encode(body))
      } onCancel: {
        Task { _ = try? await self.cancelDoctor(body.requestID) }
      }
      try Task.checkCancellation()
      return result
    } catch {
      // Detached cleanup is not cancelled with the caller. A failure to acknowledge
      // stop is reported as unknown; client disconnection is never called release.
      if Task.isCancelled {
        let acknowledged = await Task.detached { try? await self.cancelDoctor(body.requestID) }
          .value
        guard acknowledged?.status == .cancelled else {
          throw MoxError(.connectionLost, "Diagnostic check cancellation could not be confirmed.")
        }
        throw CancellationError()
      }
      throw error
    }
  }
  private func cancelDoctor(_ id: UUID) async throws -> DoctorResult {
    try await json("/doctor/\(id)/cancel", method: "POST")
  }
  public func assessResources(_ body: SamplingResolutionBody) async throws -> ResourceAssessment {
    try await json("/resources", method: "POST", body: Wire.encode(body))
  }
  public func resolveSampling(_ body: SamplingResolutionBody) async throws -> EffectiveSampling {
    try await json("/config/effective", method: "POST", body: Wire.encode(body))
  }
  public func setGlobalSampling(_ update: GlobalSamplingUpdate) async throws -> ModelConfiguration {
    try await json("/config/sampling", method: "POST", body: Wire.encode(update))
  }
  public func setModelSampling(_ id: UUID, _ update: ModelSamplingUpdate)
    async throws -> ModelInstallationSummary
  {
    try await json("/models/\(id)/sampling", method: "POST", body: Wire.encode(update))
  }
  public func setModelPinned(_ id: UUID, _ update: ModelPinUpdate)
    async throws -> ModelInstallationSummary
  {
    try await json("/models/\(id)/pin", method: "POST", body: Wire.encode(update))
  }
  public func updateRegistry(_ update: RegistryUpdate) async throws -> ModelConfiguration {
    try await json("/registries", method: "POST", body: Wire.encode(update))
  }
  public func importModel(path: String, alias: String) async throws -> ModelInstallationSummary {
    try await json("/models/import", method: "POST", body: Wire.encode(ModelImportBody(path: path, alias: alias)))
  }
  public func model(_ id: UUID) async throws -> ModelInstallationSummary {
    try await json("/models/\(id)")
  }
  public func modelAction(_ id: UUID, _ action: String) async throws -> ServiceState {
    guard ["load", "unload"].contains(action) else {
      throw MoxError(.invalidParameters, "Invalid model action.")
    }
    return try await json("/models/\(id)/\(action)", method: "POST")
  }
  public func removeModel(_ id: UUID) async throws -> ModelLibraryPage {
    try await json("/models/\(id)", method: "DELETE")
  }
  public func selectModel(_ id: UUID) async throws -> ModelLibraryPage {
    try await json("/models/\(id)/select", method: "POST")
  }
  public func library(installationOffset: Int = 0, operationOffset: Int = 0) async throws
    -> ModelLibraryPage
  {
    try await json("/library?installOffset=\(installationOffset)&operationOffset=\(operationOffset)")
  }
  public func download(_ id: UUID) async throws -> DownloadOperationSummary {
    try await json("/downloads/\(id)")
  }
  public func planPull(_ body: PullBody) async throws -> ModelDownloadPlanSummary {
    try await json("/downloads/plan", method: "POST", body: Wire.encode(body))
  }
  public func pull(_ body: PullBody) async throws -> DownloadCreated {
    try await json("/downloads", method: "POST", body: Wire.encode(body))
  }
  public func downloadAction(_ id: UUID, _ action: String) async throws -> ModelLibraryPage {
    guard ["pause", "resume", "cancel", "discard"].contains(action) else {
      throw MoxError(.invalidParameters, "Invalid download action.")
    }
    return try await json("/downloads/\(id)/\(action)", method: "POST")
  }
  private func json<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
    let transfer = BoundedTransfer(instance: discovery.identity.instanceID, requestID: nil)
    let data = try await transfer.collect(request: request(path, method: method, body: body))
    return try Wire.decode(T.self, data)
  }
}

public final class RemoteGeneration: Sendable {
  public let requestID: UUID
  private let client: ServiceClient
  private let transfer: BoundedTransfer
  private let lock = NSLock()
  private nonisolated(unsafe) var cancelled = false
  public init(client: ServiceClient, requestID: UUID, request: URLRequest) {
    self.client = client
    self.requestID = requestID
    transfer = BoundedTransfer(instance: client.discovery.identity.instanceID, requestID: requestID)
    transfer.start(request)
  }
  public var isCancelled: Bool { lock.withLock { cancelled } }
  /// A verified HTTP error rejected this submission before a stream was accepted.
  public var wasRejected: Bool { transfer.wasRejected }
  public func cancel() {
    guard !wasRejected else { return }
    let first = lock.withLock {
      if cancelled { return false }
      cancelled = true
      return true
    }
    guard first else { return }
    Task {
      // Registration and cancellation can race. Only retry this idempotent operation.
      for _ in 0..<ServiceTiming.registrationCancelAttempts {
        guard !wasRejected else { return }
        do {
          _ = try await client.cancel(requestID)
          return
        } catch let e as MoxError where e.code == .notFound {
          try? await Task.sleep(for: ServiceTiming.controlPoll)
        } catch {
          transfer.abort(MoxError(.connectionLost, "Cancellation could not reach the service."))
          return
        }
      }
      transfer.abort(MoxError(.connectionLost, "Generation registration could not be confirmed."))
    }
  }
  public func disconnect() {
    transfer.abort(MoxError(.connectionLost, "Generation connection closed."))
  }
  @discardableResult public func waitUntilStopped() async -> Bool {
    // The terminal is emitted after Core's backend barrier. On transport loss query/cancel
    // the same instance, never submit a replacement request.
    if wasRejected || transfer.receivedTerminal { return true }
    let deadline = ContinuousClock.now.advanced(by: .seconds(ServiceTiming.shutdownSeconds))
    while ContinuousClock.now < deadline {
      do {
        let state = try await client.cancel(requestID)
        if state.terminal != nil { return true }
      } catch { return false }
      try? await Task.sleep(for: ServiceTiming.stoppedPoll)
    }
    return false
  }
  public var events: Events { Events(transfer: transfer) }
  public struct Events: AsyncSequence, Sendable {
    public typealias Element = GenerationEvent
    let transfer: BoundedTransfer
    public struct AsyncIterator: AsyncIteratorProtocol {
      var iterator: AsyncThrowingStream<EventFrame, Error>.Iterator
      let transfer: BoundedTransfer
      let accepted: Bool
      public mutating func next() async throws -> GenerationEvent? {
        guard accepted else {
          throw MoxError(.protocolViolation, "Generation events allow only one consumer.")
        }
        guard let frame = try await iterator.next() else { return nil }
        transfer.consumed(frame)
        return try frame.event()
      }
    }
    public func makeAsyncIterator() -> AsyncIterator {
      .init(
        iterator: transfer.frames.makeAsyncIterator(), transfer: transfer,
        accepted: transfer.claimConsumer())
    }
  }
}

/// URLSession delegate receives finite Data chunks, checks bytes before aggregation, and
/// fails the transfer when its bounded consumer queue is full. No unbounded bytes.lines.
final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let instance: UUID
  let requestID: UUID?
  let frames: AsyncThrowingStream<EventFrame, Error>
  let continuation: AsyncThrowingStream<EventFrame, Error>.Continuation
  private let lock = NSLock()
  private var consumerClaimed = false
  func claimConsumer() -> Bool {
    lock.withLock {
      if consumerClaimed { return false }
      consumerClaimed = true
      return true
    }
  }
  private var pendingBytes = 0
  private var pendingEvents = 0
  private let delegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    return q
  }()
  private var terminal = false
  private var completed = false
  private var rejected = false
  private var completionError: Error?
  private var line = Data()
  private var frameLines: [String] = []
  private var frameBytes = 0
  private var expectedSequence = 0
  private var totalBytes = 0
  private var jsonData = Data()
  private var status = 0
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var result: CheckedContinuation<Data, Error>?
  var wasRejected: Bool { lock.withLock { rejected } }
  var receivedTerminal: Bool { lock.withLock { terminal && completed } }
  init(instance: UUID, requestID: UUID?) {
    self.instance = instance
    self.requestID = requestID
    (frames, continuation) = AsyncThrowingStream.makeStream(
      bufferingPolicy: .bufferingOldest(StreamLimits.pendingEvents + 1))
    super.init()
    continuation.onTermination = { [weak self] termination in
      if case .cancelled = termination {
        self?.abort(MoxError(.connectionLost, "Generation consumer cancelled."))
      }
    }
  }
  func start(_ request: URLRequest) {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = ServiceTiming.requestTimeout
    config.timeoutIntervalForResource = ServiceTiming.maximumStreamLifetime
    let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    lock.withLock {
      guard !completed else {
        session.invalidateAndCancel()
        return
      }
      self.session = session
      self.task = session.dataTask(with: request)
      self.task?.resume()
    }
  }
  func collect(request: URLRequest) async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { c in
        let registered = lock.withLock {
          guard !completed else {
            c.resume(
              throwing: completionError ?? MoxError(.connectionLost, "Request already ended."))
            return false
          }
          result = c
          return true
        }
        if registered { start(request) }
      }
    } onCancel: {
      self.abort(MoxError(.connectionLost, "Request cancelled."))
    }
  }
  func abort(_ error: MoxError) { delegateQueue.addOperation { self.finish(error) } }
  private func finish(_ error: Error? = nil, rejected: Bool = false) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    self.rejected = rejected
    completionError = error
    let c = result
    result = nil
    let data = jsonData
    let session = self.session
    self.session = nil
    lock.unlock()
    if let error {
      continuation.finish(throwing: error)
      c?.resume(throwing: error)
    } else {
      continuation.finish()
      c?.resume(returning: data)
    }
    session?.invalidateAndCancel()
  }
  func consumed(_ frame: EventFrame) {
    lock.withLock {
      pendingBytes -= frame.text?.utf8.count ?? 0
      pendingEvents -= 1
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    finish(MoxError(.protocolViolation, "Service redirects are forbidden."))
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
      response.value(forHTTPHeaderField: "X-Mox-Instance") == instance.uuidString
    else {
      completionHandler(.cancel)
      finish(MoxError(.incompatibleService, "Response identity does not match."))
      return
    }
    status = response.statusCode
    BuildInfo.logResponse(status: status)
    if requestID != nil, status == 200, response.mimeType != "text/event-stream" {
      completionHandler(.cancel)
      finish(MoxError(.protocolViolation, "Expected a generation event stream."))
      return
    }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      if requestID == nil || status != 200 {
        guard jsonData.count + data.count <= Wire.frameLimit else {
          throw MoxError(.protocolViolation, "JSON response exceeds limit.")
        }
        jsonData.append(data)
        return
      }
      for byte in data {
        guard line.count < Wire.frameLimit else {
          throw MoxError(.protocolViolation, "Event line exceeds limit.")
        }
        if byte == 10 {
          if line.last == 13 { line.removeLast() }
          guard let value = String(data: line, encoding: .utf8) else {
            throw MoxError(.protocolViolation, "Invalid UTF-8 event.")
          }
          line.removeAll(keepingCapacity: true)
          if value.isEmpty {
            try decodeFrame()
            frameLines.removeAll(keepingCapacity: true)
            frameBytes = 0
          } else if !value.hasPrefix(":") {
            frameBytes += value.utf8.count
            guard frameBytes <= Wire.frameLimit, frameLines.count < 8 else {
              throw MoxError(.protocolViolation, "Event frame exceeds limit.")
            }
            frameLines.append(value)
          }
        } else {
          line.append(byte)
        }
      }
    } catch { finish(error) }
  }
  private func decodeFrame() throws {
    if frameLines.isEmpty { return }
    guard frameLines.count == 3, frameLines[0] == "event: generation",
      frameLines[1] == "id: \(expectedSequence)", frameLines[2].hasPrefix("data: ")
    else { throw MoxError(.protocolViolation, "Malformed SSE framing.") }
    let frame = try Wire.decode(EventFrame.self, Data(frameLines[2].dropFirst(6).utf8))
    guard frame.instanceID == instance, frame.requestID == requestID,
      frame.sequence == expectedSequence, !lock.withLock({ terminal })
    else { throw MoxError(.protocolViolation, "Out-of-order or stale generation event.") }
    let event = try frame.event()
    let bytes = frame.text?.utf8.count ?? 0
    totalBytes += bytes
    guard totalBytes <= Wire.bodyLimit else {
      throw MoxError(.slowConsumer, "Output exceeds 16 MiB safety limit.")
    }
    let fits = lock.withLock {
      pendingBytes += bytes
      pendingEvents += 1
      return pendingBytes <= StreamLimits.pendingTextBytes
        && pendingEvents <= (StreamLimits.pendingEvents + (event.payload.isTerminal ? 1 : 0))
    }
    guard fits else { throw MoxError(.slowConsumer, "Client output queue exceeded byte limit.") }
    expectedSequence += 1
    if event.payload.isTerminal { lock.withLock { terminal = true } }
    switch continuation.yield(frame) {
    case .dropped: throw MoxError(.slowConsumer, "Client output queue exceeded event limit.")
    case .terminated: throw MoxError(.connectionLost, "Client stopped consuming output.")
    case .enqueued: break
    @unknown default: throw MoxError(.protocolViolation, "Unknown queue state.")
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if status >= 400, let envelope = try? Wire.decode(ErrorEnvelope.self, jsonData) {
      finish(envelope.error, rejected: requestID != nil)
    } else if error != nil {
      finish(MoxError(.connectionLost, "Connection to model service was lost."))
    } else if status != 200 && status != 202 {
      finish(MoxError(.protocolViolation, "Unexpected HTTP response."))
    } else if requestID != nil
      && (!lock.withLock({ terminal }) || !line.isEmpty || !frameLines.isEmpty)
    {
      finish(MoxError(.connectionLost, "Event stream ended without a complete terminal."))
    } else {
      finish()
    }
  }
}
