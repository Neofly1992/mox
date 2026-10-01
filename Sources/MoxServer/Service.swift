import Foundation
import Hummingbird
import HummingbirdCore
import MoxCore
import MoxDomain
import MoxProtocol
import NIOCore
import OSLog

struct ServiceContext: RequestContext {
  var coreContext: CoreRequestContextStorage
  let channel: any Channel
  init(source: Source) {
    coreContext = .init(source: source)
    channel = source.channel
  }
}

private enum ServiceCapacity {
  static let rememberedRequestIDs = 100_000
  static let terminalDetails = 256
  static let terminalRetention: Duration = .seconds(300)
  static let connections = 64
}

public actor InferenceService {
  public let identity: ServiceIdentity
  private let token: String
  private let runtime: RuntimeCoordinator
  private let downloads: DownloadManager?
  private var publicAPI: PublicAPIManager?
  private var handles: [UUID: GenerationHandle] = [:]
  private var publicRequestIDs = Set<UUID>()
  private var states: [UUID: RequestState] = [:]
  private var completed: [(UUID, ContinuousClock.Instant)] = []
  private var seen = Set<UUID>()
  private var revision: UInt64 = 0
  private var draining = false
  private let library: ModelLibraryService
  private var diagnostics = DiagnosticRing()
  public init(
    identity: ServiceIdentity, token: String, runtime: RuntimeCoordinator,
    downloads: DownloadManager? = nil, sources: (any ModelSourceFactory)? = nil,
    launchSampling: SamplingSettings = .init()
  ) {
    self.identity = identity
    self.token = token
    self.runtime = runtime
    self.downloads = downloads
    self.library = ModelLibraryService(
      downloads: downloads, runtime: runtime,
      sources: sources, launchSampling: launchSampling)
  }
  public func restoreLibrarySettings() async throws { try await library.restoreRuntimeSettings() }
  public func shutdown() async {
    draining = true
    revision &+= 1
    await publicAPI?.shutdown()
    let active = Array(handles.values)
    active.forEach { $0.cancel() }
    for handle in active { await handle.waitUntilStopped() }
    await downloads?.shutdown()
    await runtime.shutdown()
  }
  public func attachPublicAPI(_ manager: PublicAPIManager) { publicAPI = manager }
  private func recordFailure(_ failure: Error, path: String) {
    let stage: String
    switch path {
    case "/mox/v1/public-api", "/mox/v1/public-api/rotate": stage = "public.control"
    case "/mox/v1/registries", "/mox/v1/config/default": stage = "source.configuration"
    case "/mox/v1/downloads", "/mox/v1/downloads/plan": stage = "download.create"
    case "/mox/v1/models/import": stage = "model.import"
    default:
      stage =
        path.hasPrefix("/mox/v1/downloads/")
        ? "download.action"
        : path.hasPrefix("/mox/v1/models/") ? "model.action" : "server.management"
    }
    let nsError = failure as NSError
    diagnostics.record(
      .init(
        stage: stage,
        code: (failure as? MoxError)?.code.rawValue ?? "internalFailure",
        instanceID: identity.instanceID,
        systemDomain: failure is MoxError ? nil : nsError.domain,
        systemCode: failure is MoxError ? nil : nsError.code))
  }
  public func diagnosticEvents() async -> [DiagnosticEvent] {
    var events = diagnostics.events
    events += await library.diagnosticEvents().map {
      DiagnosticEvent(stage: $0.stage, code: $0.code, instanceID: identity.instanceID)
    }
    if let downloads {
      do {
        events += try await downloads.diagnosticOperations().compactMap { operation in
          guard
            operation.phase.isActive || operation.phase == .failed
              || operation.phase == .interrupted
          else { return nil }
          return DiagnosticEvent(
            stage: "download.\(operation.phase.rawValue)",
            code: operation.errorCode ?? operation.phase.rawValue,
            instanceID: identity.instanceID, operationID: operation.id,
            systemDomain: operation.failureDomain, systemCode: operation.failureSystemCode)
        }
      } catch {
        events.append(
          .init(
            stage: "download.diagnostics", code: "storageFailed", instanceID: identity.instanceID))
      }
    }
    if let publicAPI, let code = await publicAPI.status().errorCode {
      events.append(
        .init(
          stage: "public.listener", code: code,
          instanceID: identity.instanceID))
    }
    if let recovery = await downloads?.recoveryStatus(), recovery.phase == .failed {
      events.append(
        .init(
          stage: "library.recovery", code: recovery.errorCode ?? "storageFailed",
          instanceID: identity.instanceID))
    }
    return Array(events.suffix(256))
  }
  public func publicModels() async throws -> Data {
    guard let downloads else { throw MoxError(.shuttingDown, "Model library is unavailable.") }
    var items: [ModelInstallationSummary] = []
    var offset = 0
    while true {
      let page = try await downloads.installationSummaries(offset: offset)
      items += page
      if page.count < 100 { break }
      offset += page.count
    }
    let models = items.filter {
      ($0.availability == .ready || $0.availability == .checking) && !$0.deletionPending
    }.map {
      [
        "id": $0.alias, "object": "model", "created": 0,
        "owned_by": "mox",
      ] as [String: Any]
    }
    return try JSONSerialization.data(withJSONObject: ["object": "list", "data": models])
  }
  public func resolveSampling(
    model: GenerateBody.Model,
    explicit: SamplingSettings = .init()
  ) async throws -> EffectiveSampling {
    try await library.resolveSampling(try modelReference(model), explicit: explicit)
  }
  private func modelReference(_ model: GenerateBody.Model) throws -> ModelReference {
    switch model.kind {
    case "installedAlias": return .installed(model.path)
    case "localDirectory": return .directory(model.path)
    default: throw MoxError(.invalidParameters, "Unknown model reference kind.")
    }
  }
  public func beginPublic(model: String, request: GenerationRequest) async throws
    -> GenerationHandle
  {
    try await beginPublic(
      model: model, request: request,
      explicitSampling: SamplingSettings(request.sampling))
  }
  public func beginPublic(
    model: String, request: GenerationRequest,
    explicitSampling: SamplingSettings
  ) async throws -> GenerationHandle {
    let handle = try await begin(
      model: .init(kind: "installedAlias", path: model),
      request: request, explicitSampling: explicitSampling, requireVerifiedTools: true)
    publicRequestIDs.insert(request.id)
    return handle
  }
  public func stopPublicGenerations() async {
    let active = publicRequestIDs.compactMap { handles[$0] }
    active.forEach { $0.cancel() }
    for handle in active { await handle.waitUntilStopped() }
    publicRequestIDs.subtract(active.map(\.requestID))
  }
  public func observePublic(_ event: GenerationEvent) { observe(event) }
  private func prune() {
    while let first = completed.first,
      completed.count > ServiceCapacity.terminalDetails
        || first.1.duration(to: .now) > ServiceCapacity.terminalRetention
    {
      completed.removeFirst()
      states.removeValue(forKey: first.0)
    }
  }
  public func snapshot() async throws -> ServiceState {
    prune()
    let snap = await runtime.snapshot()
    let models = await runtime.modelStates().map { ModelState(modelID: $0.id, state: $0.state) }
    let activeDownloads = try await downloads?.activeOperationCount() ?? 0
    return ServiceState(
      instanceID: identity.instanceID, revision: revision,
      serviceState: draining ? "draining" : "running", ownership: identity.ownership,
      residentModels: snap.residentModels, reservedBytes: snap.reservedBytes,
      activeLeases: snap.activeLeases, queued: snap.queued,
      budgetBytes: snap.budgetBytes, queueCapacity: snap.queueCapacity,
      queueTimeoutSeconds: snap.queueTimeoutSeconds,
      activeDownloads: activeDownloads, models: models,
      requests: states.values.filter { $0.terminal == nil }.sorted {
        $0.requestID.uuidString < $1.requestID.uuidString
      }, libraryRecovery: await downloads?.recoveryStatus() ?? .init())
  }
  private func begin(_ body: GenerateBody, output: GenerationHandle) async throws
    -> GenerationHandle
  {
    try await begin(
      model: body.model, request: body.domain(), explicitSampling: body.samplingSettings,
      output: output)
  }
  private func begin(
    model: GenerateBody.Model, request: GenerationRequest,
    explicitSampling: SamplingSettings, requireVerifiedTools: Bool = false,
    output: GenerationHandle? = nil
  ) async throws -> GenerationHandle {
    let reference = try modelReference(model)
    guard !draining else { throw MoxError(.shuttingDown, "Service is stopping.") }
    guard !seen.contains(request.id) else {
      throw MoxError(.busy, "Request ID was already submitted; do not replay it.")
    }
    guard seen.count < ServiceCapacity.rememberedRequestIDs else {
      throw MoxError(.resourceLimit, "Request identity capacity reached; restart the idle service.")
    }
    seen.insert(request.id)
    let handle = output ?? GenerationHandle(requestID: request.id)
    handles[request.id] = handle
    states[request.id] = .init(requestID: request.id, modelID: "preparing", phase: "preparing")
    revision &+= 1
    do {
      let modelID = try await library.startGeneration(
        reference, request: request,
        explicitSampling: explicitSampling, requireVerifiedTools: requireVerifiedTools,
        output: handle)
      states[request.id]?.modelID = modelID
    } catch {
      for await event in handle.events { observe(event) }
      throw error
    }
    return handle
  }
  private func observe(_ event: GenerationEvent) {
    guard var state = states[event.requestID] else { return }
    state.lastSequence = event.sequence
    if case .phase(let phase) = event.payload { state.phase = phase }
    if event.payload.isTerminal {
      state.terminal = EventFrame(instanceID: identity.instanceID, event: event)
      state.stopping = false
      completed.append((event.requestID, .now))
      handles.removeValue(forKey: event.requestID)
      publicRequestIDs.remove(event.requestID)
    }
    states[event.requestID] = state
    revision &+= 1
    prune()
  }
  private func cancel(_ id: UUID) throws -> RequestState {
    prune()
    guard var state = states[id] else {
      throw MoxError(.notFound, "Request is unknown or its terminal detail expired.")
    }
    if let handle = handles[id] {
      handle.cancel()
      state.stopping = true
      states[id] = state
      revision &+= 1
    }
    return state
  }
  func response(_ request: Request, context: ServiceContext) async -> Response {
    var bodyConsumed =
      request.headers[.transferEncoding] == nil
      && (request.headers[.contentLength].flatMap(Int.init) ?? 0) == 0
    do {
      guard request.headers[.origin] == nil else {
        return error(
          MoxError(.authenticationFailed, "Browser origins are not allowed."), status: .forbidden,
          closing: context.channel)
      }
      guard request.headers[.authorization] == "Bearer \(token)" else {
        return error(
          MoxError(.authenticationFailed, "Management authentication failed."),
          status: .unauthorized, closing: context.channel)
      }
      let path = request.uri.path
      let modelSettingsBody =
        request.method == .post && path.hasPrefix("/mox/v1/models/")
        && (path.hasSuffix("/sampling") || path.hasSuffix("/pin"))
      let acceptsBody =
        request.method == .post
        && ([
          "/mox/v1/generations", "/mox/v1/downloads", "/mox/v1/downloads/plan",
          "/mox/v1/registries", "/mox/v1/config/default", "/mox/v1/config/sampling",
          "/mox/v1/config/effective", "/mox/v1/models/import", "/mox/v1/public-api",
        ]
        .contains(path) || modelSettingsBody)
      if !acceptsBody,
        request.headers[.transferEncoding] != nil
          || (request.headers[.contentLength].flatMap(Int.init) ?? 0) > 0
      {
        return error(
          MoxError(.invalidParameters, "This endpoint requires an empty body."),
          status: .badRequest, closing: context.channel)
      }
      if request.method == .get, path == "/mox/v1/identity" { return try json(identity) }
      if request.method == .get, path == "/mox/v1/state" { return try json(try await snapshot()) }
      if request.method == .get, path == "/mox/v1/diagnostics" {
        return try json(await diagnosticEvents())
      }
      if request.method == .get, path == "/mox/v1/public-api" {
        guard let publicAPI else {
          throw MoxError(.shuttingDown, "Public API control is unavailable.")
        }
        return try json(await publicAPI.status())
      }
      if request.method == .get, path == "/mox/v1/public-api/key" {
        guard let publicAPI, let key = try await publicAPI.currentKey() else {
          throw MoxError(.notFound, "Public API key has not been created.")
        }
        return try json(key)
      }
      if request.method == .post, path == "/mox/v1/public-api/rotate" {
        guard let publicAPI else {
          throw MoxError(.shuttingDown, "Public API control is unavailable.")
        }
        return try json(try await publicAPI.rotateKey())
      }
      if request.method == .post, path == "/mox/v1/public-api" {
        guard let publicAPI else {
          throw MoxError(.shuttingDown, "Public API control is unavailable.")
        }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 1024, description: "Public API setting exceeds 1 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(PublicAPIChange.self, data)
        return try json(try await publicAPI.setEnabled(body.enabled))
      }
      if request.method == .post, path == "/mox/v1/config/default" {
        guard let downloads else {
          throw MoxError(.shuttingDown, "Source settings are unavailable.")
        }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 4096, description: "Source settings exceed 4 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(DefaultRegistryUpdate.self, data)
        return try json(
          try await downloads.setDefaultRegistry(
            body.registryID, expectedRevision: body.expectedRevision))
      }
      if request.method == .post, path == "/mox/v1/config/sampling" {
        guard let downloads else { throw MoxError(.shuttingDown, "Settings are unavailable.") }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 4096, description: "Sampling settings exceed 4 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(GlobalSamplingUpdate.self, data)
        return try json(
          try await downloads.setGlobalSampling(
            body.settings,
            expectedRevision: body.expectedRevision))
      }
      if request.method == .post, path == "/mox/v1/config/effective" {
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 4096, description: "Sampling request exceeds 4 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(SamplingResolutionBody.self, data)
        return try json(try await resolveSampling(model: body.model, explicit: body.explicit))
      }
      if request.method == .post, path == "/mox/v1/registries" {
        guard downloads != nil else {
          throw MoxError(.shuttingDown, "Source settings are unavailable.")
        }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 16_384, description: "Source settings exceed 16 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(RegistryUpdate.self, data)
        return try json(
          try await library.updateRegistry(
            body.registry,
            expectedRevision: body.expectedRevision, credential: body.credential,
            mirrorCredential: body.mirrorCredential))
      }
      if request.method == .get, path == "/mox/v1/library" {
        guard let downloads else { throw MoxError(.shuttingDown, "Model library is unavailable.") }
        let query = URLComponents(string: "http://localhost\(request.uri)")?.queryItems ?? []
        func offset(_ name: String) throws -> Int {
          guard let value = query.first(where: { $0.name == name })?.value else { return 0 }
          guard let number = Int(value), (0...1_000_000).contains(number) else {
            throw MoxError(.invalidParameters, "Invalid model library page offset.")
          }
          return number
        }
        return try json(
          try await downloads.page(
            installationOffset: offset("installOffset"), operationOffset: offset("operationOffset"))
        )
      }
      if request.method == .post, path == "/mox/v1/models/import" {
        guard let downloads else { throw MoxError(.shuttingDown, "Model library is unavailable.") }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 16_384, description: "Import request exceeds 16 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(ModelImportBody.self, data)
        return try json(
          ModelInstallationSummary(
            try await downloads.importDirectory(path: body.path, alias: body.alias)))
      }
      let modelParts = path.split(separator: "/")
      if modelParts.count >= 4, modelParts.prefix(3).joined(separator: "/") == "mox/v1/models",
        let id = UUID(uuidString: String(modelParts[3])), let downloads
      {
        let item = try await downloads.installation(id)
        if request.method == .get, modelParts.count == 4 {
          return try json(ModelInstallationSummary(item))
        }
        if request.method == .post, modelParts.count == 5 {
          if modelParts[4] == "sampling" || modelParts[4] == "pin" {
            let data = try await RequestBodyReader.read(
              request, channel: context.channel,
              limit: 4096, description: "Model settings exceed 4 KiB.")
            bodyConsumed = true
            if modelParts[4] == "sampling" {
              let body = try Wire.decode(ModelSamplingUpdate.self, data)
              return try json(
                ModelInstallationSummary(
                  try await downloads.setModelSampling(
                    id,
                    settings: body.settings, expectedRevision: body.expectedRevision)))
            }
            let body = try Wire.decode(ModelPinUpdate.self, data)
            return try json(
              ModelInstallationSummary(
                try await library.setPinned(
                  id,
                  pinned: body.pinned, expectedRevision: body.expectedRevision)))
          }
          switch modelParts[4] {
          case "select":
            try await downloads.selectInstallation(id)
            return try json(try await downloads.page())
          case "load": try await library.load(id)
          case "unload": try await library.unload(id)
          default: throw MoxError(.notFound, "Unknown model action.")
          }
          return try json(try await snapshot())
        }
      }
      if request.method == .delete, path.hasPrefix("/mox/v1/models/") {
        guard let downloads,
          let id = UUID(uuidString: String(path.dropFirst("/mox/v1/models/".count)))
        else {
          throw MoxError(.notFound, "Model installation was not found.")
        }
        try await library.removeInstallation(id)
        return try json(try await downloads.page())
      }
      if request.method == .post, path == "/mox/v1/downloads" || path == "/mox/v1/downloads/plan" {
        guard downloads != nil else {
          throw MoxError(.shuttingDown, "Model downloads are unavailable.")
        }
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: 16_384, description: "Download request exceeds 16 KiB.")
        bodyConsumed = true
        let body = try Wire.decode(PullBody.self, data)
        let reference = ModelPullRequest(
          registryID: body.registryID, provider: body.provider,
          endpoint: body.endpoint, repository: body.repository, selector: body.selector,
          variant: body.variant)
        if path == "/mox/v1/downloads/plan" {
          return try json(ModelDownloadPlanSummary(try await library.planDownload(reference)))
        }
        let id = try await library.startDownload(reference)
        return try json(DownloadCreated(id: id), status: .accepted)
      }
      let downloadParts = path.split(separator: "/")
      if request.method == .get, downloadParts.count == 4,
        downloadParts.prefix(3).joined(separator: "/") == "mox/v1/downloads",
        let id = UUID(uuidString: String(downloadParts[3])), let downloads
      {
        let item = try await downloads.operation(id)
        return try json(DownloadOperationSummary(item))
      }
      if request.method == .post, downloadParts.count == 5,
        downloadParts.prefix(3).joined(separator: "/") == "mox/v1/downloads",
        let id = UUID(uuidString: String(downloadParts[3])), let downloads
      {
        switch downloadParts[4] {
        case "pause": try await downloads.pause(id)
        case "cancel": try await downloads.cancel(id)
        case "discard": try await downloads.discard(id)
        case "resume":
          try await library.resumeDownload(id)
        default: throw MoxError(.notFound, "Unknown download action.")
        }
        return try json(try await downloads.page())
      }
      if request.method == .post, path == "/mox/v1/generations" {
        let data = try await RequestBodyReader.read(
          request, channel: context.channel,
          limit: Wire.bodyLimit, description: "Request exceeds 16 MiB.")
        bodyConsumed = true
        let body: GenerateBody
        do { body = try GenerateBody.decode(data) } catch let e as MoxError { throw e } catch {
          throw MoxError(.invalidParameters, "Invalid generation JSON.")
        }
        let handle = GenerationHandle(requestID: body.requestID)
        let channel = context.channel
        channel.closeFuture.whenComplete { _ in handle.cancel() }
        _ = try await begin(body, output: handle)
        let instanceID = identity.instanceID
        return Response(
          status: .ok,
          headers: [
            .contentType: "text/event-stream", .cacheControl: "no-store",
            .init("X-Mox-Instance")!: instanceID.uuidString,
          ],
          body: ResponseBody { writer in
            // One pending event pull, with heartbeat ticks through a size-one wake stream.
            // The event stays in Core until consumed; heartbeat coalescing never drops content.
            let delivery = Delivery()
            let pump = Task {
              for await event in handle.events {
                await self.observe(event)
                // Delivery rendezvous provides backpressure with no second event queue.
                await delivery.send(event)
              }
              await delivery.finish()
            }
            defer { pump.cancel() }
            do {
              while true {
                let item = await delivery.next(timeout: ServiceTiming.heartbeat)
                if case .end = item { break }
                let bytes: Data
                switch item {
                case .event(let event):
                  bytes = try EventFrame(instanceID: instanceID, event: event).sse()
                case .heartbeat: bytes = Data(": heartbeat\n\n".utf8)
                case .end: bytes = Data()
                }
                let deadline = Task {
                  try await Task.sleep(for: ServiceTiming.writeDeadline)
                  try? await channel.close().get()
                }
                do {
                  try await writer.write(ByteBuffer(bytes: bytes))
                  deadline.cancel()
                } catch {
                  deadline.cancel()
                  throw error
                }
              }
              try await writer.finish(nil)
            } catch {
              handle.cancel()
              await delivery.close()
              await pump.value
              await handle.waitUntilStopped()
              throw error
            }
            await handle.waitUntilStopped()
          })
      }
      let parts = path.split(separator: "/")
      if parts.count >= 4, parts.prefix(3).joined(separator: "/") == "mox/v1/generations",
        let id = UUID(uuidString: String(parts[3]))
      {
        if request.method == .post, parts.count == 5, parts[4] == "cancel" {
          let state = try cancel(id)
          return try json(state, status: state.terminal == nil ? .accepted : .ok)
        }
        if request.method == .get, parts.count == 4 {
          prune()
          guard let state = states[id] else {
            throw MoxError(.notFound, "Request is unknown or expired.")
          }
          return try json(state)
        }
      }
      throw MoxError(.notFound, "Private endpoint not found.")
    } catch let e as MoxError {
      recordFailure(e, path: request.uri.path)
      return error(e, closing: bodyConsumed ? nil : context.channel)
    } catch {
      recordFailure(error, path: request.uri.path)
      return self.error(
        MoxError(.generationFailed, "Service operation failed; inspect diagnostics."),
        closing: bodyConsumed ? nil : context.channel)
    }
  }
  private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response
  {
    Response(
      status: status,
      headers: [
        .contentType: "application/json", .cacheControl: "no-store",
        .init("X-Mox-Instance")!: identity.instanceID.uuidString,
      ], body: .init(byteBuffer: ByteBuffer(bytes: try Wire.encode(value))))
  }
  private func error(
    _ value: MoxError, status: HTTPResponse.Status? = nil, closing channel: (any Channel)? = nil
  ) -> Response {
    let code = status ?? HTTPFailureStatus.status(value)
    var response =
      (try? json(ErrorEnvelope(instanceID: identity.instanceID, error: value), status: code))
      ?? Response(status: .internalServerError)
    if let channel {
      response.headers[.connection] = "close"
      let bytes =
        (try? Wire.encode(ErrorEnvelope(instanceID: identity.instanceID, error: value))) ?? Data()
      response.body = RequestBodyReader.rejectedBody(bytes, closing: channel)
    }
    return response
  }
}

/// Single-slot rendezvous. Cancelled network writers close it to release a blocked producer.
private actor Delivery {
  enum Item: Sendable {
    case event(GenerationEvent)
    case heartbeat, end
  }
  var item: GenerationEvent?
  var reader: CheckedContinuation<Item, Never>?
  var sender: CheckedContinuation<Void, Never>?
  var ended = false
  func send(_ event: GenerationEvent) async {
    guard !ended else { return }
    if let reader {
      self.reader = nil
      reader.resume(returning: .event(event))
      return
    }
    item = event
    await withCheckedContinuation { sender = $0 }
  }
  func next(timeout: Duration) async -> Item {
    if let item {
      self.item = nil
      sender?.resume()
      sender = nil
      return .event(item)
    }
    if ended { return .end }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled { tick() }
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { reader = $0 }
  }
  func tick() {
    reader?.resume(returning: .heartbeat)
    reader = nil
  }
  func finish() {
    ended = true
    reader?.resume(returning: .end)
    reader = nil
  }
  func close() {
    ended = true
    item = nil
    sender?.resume()
    sender = nil
    reader?.resume(returning: .end)
    reader = nil
  }
}

public struct PrivateServer: Sendable {
  let service: InferenceService
  public init(service: InferenceService) { self.service = service }
  public func run(onReady: @escaping @Sendable (Int) async -> Void) async throws {
    let router = Router(context: ServiceContext.self)
    router.get("/**") { request, context in await service.response(request, context: context) }
    router.post("/**") { request, context in await service.response(request, context: context) }
    router.delete("/**") { request, context in await service.response(request, context: context) }
    let app = Application(
      router: router,
      server: .http1(
        configuration: .init(idleTimeout: .seconds(RequestBodyReader.idleTimeoutSeconds))),
      configuration: .init(
        address: .hostname("127.0.0.1", port: 0), serverName: "Mox",
        availableConnectionsDelegate: MaximumAvailableConnections(ServiceCapacity.connections)),
      onServerRunning: { channel in
        if let port = channel.localAddress?.port { await onReady(port) }
      })
    try await app.run()
  }
}
