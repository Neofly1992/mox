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
  private let sources: (any ModelSourceFactory)?
  private var handles: [UUID: GenerationHandle] = [:]
  private var states: [UUID: RequestState] = [:]
  private var completed: [(UUID, ContinuousClock.Instant)] = []
  private var seen = Set<UUID>()
  private var revision: UInt64 = 0
  private var draining = false
  private var submittingPaths = Set<String>()
  private var removingPaths = Set<String>()
  public init(
    identity: ServiceIdentity, token: String, runtime: RuntimeCoordinator,
    downloads: DownloadManager? = nil, sources: (any ModelSourceFactory)? = nil
  ) {
    self.identity = identity
    self.token = token
    self.runtime = runtime
    self.downloads = downloads
    self.sources = sources
  }
  private func resolvePull(_ body: PullBody, downloads: DownloadManager,
    sources: any ModelSourceFactory
  ) async throws -> (any ResolvedModelSource, ArtifactManifest, URL) {
    let registry = try await downloads.registry(body.registryID)
    guard registry.provider == body.provider else {
      throw MoxError(.invalidParameters, "Source protocol does not match its configuration.")
    }
    let endpoint = registry.mirror ?? registry.origin
    guard body.endpoint == endpoint else {
      throw MoxError(.invalidParameters, "Selected source endpoint changed; refresh its settings.")
    }
    let source = try sources.make(provider: registry.provider, endpoint: endpoint,
      credentialReference: registry.credentialReference(for: endpoint))
    let manifest = try await source.resolve(registryID: body.registryID,
      repository: body.repository, selector: body.selector, variant: body.variant)
    return (source, manifest, endpoint)
  }
  public func shutdown() async {
    draining = true
    revision &+= 1
    await downloads?.shutdown()
    await runtime.shutdown()
  }
  private func prune() {
    while let first = completed.first,
      completed.count > ServiceCapacity.terminalDetails
        || first.1.duration(to: .now) > ServiceCapacity.terminalRetention
    {
      completed.removeFirst()
      states.removeValue(forKey: first.0)
    }
  }
  public func snapshot() async -> ServiceState {
    prune()
    let snap = await runtime.snapshot()
    let models = await runtime.modelStates().map { ModelState(modelID: $0.id, state: $0.state) }
    return ServiceState(
      instanceID: identity.instanceID, revision: revision,
      serviceState: draining ? "draining" : "running", ownership: identity.ownership,
      residentModels: snap.residentModels, reservedBytes: snap.reservedBytes,
      activeLeases: snap.activeLeases, queued: snap.queued, models: models,
      requests: states.values.filter { $0.terminal == nil }.sorted {
        $0.requestID.uuidString < $1.requestID.uuidString
      })
  }
  private func begin(_ body: GenerateBody) async throws -> GenerationHandle {
    guard !draining else { throw MoxError(.shuttingDown, "Service is stopping.") }
    guard !seen.contains(body.requestID) else {
      throw MoxError(.busy, "Request ID was already submitted; do not replay it.")
    }
    guard seen.count < ServiceCapacity.rememberedRequestIDs else {
      throw MoxError(.resourceLimit, "Request identity capacity reached; restart the idle service.")
    }
    let request = try body.domain()
    // Freeze deletion admission before validating and waiting for runtime resources.
    let reference: String
    if body.model.kind == "installedAlias" {
      guard let item = await downloads?.snapshot().installations.first(where: {
        $0.alias == body.model.path && $0.availability == .ready && !$0.deletionPending
      }) else { throw MoxError(.notFound, "Installed model alias is unavailable.") }
      reference = item.path
    } else {
      reference = body.model.path
    }
    let path = URL(fileURLWithPath: reference).standardizedFileURL.resolvingSymlinksInPath().path
    if let installation = await downloads?.snapshot().installations.first(where: { $0.path == path }),
      installation.availability != .ready || installation.deletionPending
    {
      throw MoxError(.invalidModel, "Managed model is unavailable; inspect or remove the installation.")
    }
    guard !removingPaths.contains(path) else {
      throw MoxError(.busy, "Model removal is in progress.")
    }
    submittingPaths.insert(path)
    defer { submittingPaths.remove(path) }
    let model = try LocalModel(path: path)
    seen.insert(body.requestID)
    let handle = try await runtime.generate(model: model, request: request)
    handles[request.id] = handle
    states[request.id] = .init(requestID: request.id, modelID: model.id)
    revision &+= 1
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
      if !(request.method == .post && (path == "/mox/v1/generations" || path == "/mox/v1/downloads" || path == "/mox/v1/downloads/plan" || path == "/mox/v1/registries" || path == "/mox/v1/config/default" || path == "/mox/v1/models/import")),
        request.headers[.transferEncoding] != nil
          || (request.headers[.contentLength].flatMap(Int.init) ?? 0) > 0
      {
        return error(
          MoxError(.invalidParameters, "This endpoint requires an empty body."),
          status: .badRequest, closing: context.channel)
      }
      if request.method == .get, path == "/mox/v1/identity" { return try json(identity) }
      if request.method == .get, path == "/mox/v1/state" { return try json(await snapshot()) }
      if request.method == .post, path == "/mox/v1/config/default" {
        guard let downloads else { throw MoxError(.shuttingDown, "Source settings are unavailable.") }
        var data = Data()
        for try await buffer in request.body {
          guard buffer.readableBytes <= 4096 - data.count else {
            throw MoxError(.bodyTooLarge, "Source settings exceed 4 KiB.")
          }
          data.append(contentsOf: buffer.readableBytesView)
        }
        let body = try Wire.decode(DefaultRegistryUpdate.self, data)
        return try json(try await downloads.setDefaultRegistry(
          body.registryID, expectedRevision: body.expectedRevision))
      }
      if request.method == .post, path == "/mox/v1/registries" {
        guard let downloads, let sources else { throw MoxError(.shuttingDown, "Source settings are unavailable.") }
        if let length = request.headers[.contentLength].flatMap(Int.init), length > 16_384 {
          throw MoxError(.bodyTooLarge, "Source settings exceed 16 KiB.")
        }
        var data = Data()
        for try await buffer in request.body {
          guard buffer.readableBytes <= 16_384 - data.count else {
            throw MoxError(.bodyTooLarge, "Source settings exceed 16 KiB.")
          }
          data.append(contentsOf: buffer.readableBytesView)
        }
        let body = try Wire.decode(RegistryUpdate.self, data)
        guard body.expectedRevision == (await downloads.snapshot()).configuration.revision else {
          throw MoxError(.busy, "Source configuration changed; reload and try again.")
        }
        var registry = body.registry
        // Validate both endpoints even when no credential is provided.
        _ = try sources.make(provider: registry.provider, endpoint: registry.origin, credentialReference: nil)
        if let mirror = registry.mirror {
          _ = try sources.make(provider: registry.provider, endpoint: mirror, credentialReference: nil)
        }
        let previous = try? await downloads.registry(registry.id)
        if let previous {
          guard previous.origin == registry.origin, previous.provider == registry.provider else {
            throw MoxError(.busy, "Create a new source for a different origin or protocol.")
          }
          registry.credentialReference = previous.credentialReference
          registry.mirrorCredentialReference = previous.mirror == registry.mirror
            ? previous.mirrorCredentialReference : nil
        } else {
          registry.credentialReference = nil
          registry.mirrorCredentialReference = nil
        }
        var stagedCredentials: [String] = []
        let updated: ModelConfiguration
        do {
          if let credential = body.credential {
            let reference = try sources.saveCredential(
              credential, registryID: registry.id, endpoint: registry.origin)
            stagedCredentials.append(reference)
            registry.credentialReference = reference
          }
          if let credential = body.mirrorCredential, let mirror = registry.mirror {
            let reference = try sources.saveCredential(
              credential, registryID: registry.id, endpoint: mirror)
            stagedCredentials.append(reference)
            registry.mirrorCredentialReference = reference
          }
          updated = try await downloads.updateRegistry(
            registry, expectedRevision: body.expectedRevision)
        } catch {
          var cleanupFailed = false
          for reference in stagedCredentials {
            do { try sources.deleteCredential(reference: reference) }
            catch { cleanupFailed = true }
          }
          if cleanupFailed {
            throw MoxError(.storageFailed, "Unused source credentials could not be removed from Keychain.")
          }
          throw error
        }
        if let previous {
          let activeReferences = Set(updated.registries.flatMap {
            [$0.credentialReference, $0.mirrorCredentialReference].compactMap { $0 }
          })
          for reference in [previous.credentialReference, previous.mirrorCredentialReference].compactMap({ $0 })
            where !activeReferences.contains(reference)
          {
            do { try sources.deleteCredential(reference: reference) }
            catch {
              Logger(subsystem: "dev.mox", category: "source")
                .error("stage=keychain cleanup=failed")
            }
          }
        }
        return try json(updated)
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
        return try json(ModelLibraryPage(await downloads.snapshot(),
          installationOffset: offset("installOffset"), operationOffset: offset("operationOffset")))
      }
      if request.method == .post, path == "/mox/v1/models/import" {
        guard let downloads else { throw MoxError(.shuttingDown, "Model library is unavailable.") }
        var data = Data()
        for try await buffer in request.body {
          guard buffer.readableBytes <= 16_384 - data.count else {
            throw MoxError(.bodyTooLarge, "Import request exceeds 16 KiB.")
          }
          data.append(contentsOf: buffer.readableBytesView)
        }
        let body = try Wire.decode(ModelImportBody.self, data)
        return try json(ModelInstallationSummary(try await downloads.importDirectory(path: body.path, alias: body.alias)))
      }
      let modelParts = path.split(separator: "/")
      if modelParts.count >= 4, modelParts.prefix(3).joined(separator: "/") == "mox/v1/models",
        let id = UUID(uuidString: String(modelParts[3])), let downloads
      {
        let item = try await downloads.installation(id)
        if request.method == .get, modelParts.count == 4 { return try json(ModelInstallationSummary(item)) }
        if request.method == .post, modelParts.count == 5 {
          let normalized = URL(fileURLWithPath: item.path).standardizedFileURL.resolvingSymlinksInPath().path
          guard !removingPaths.contains(normalized) else {
            throw MoxError(.busy, "Model removal is in progress.")
          }
          switch modelParts[4] {
          case "select":
            return try json(ModelLibraryPage(try await downloads.selectInstallation(id)))
          case "load":
            if let installation = await downloads.snapshot().installations.first(where: { $0.path == normalized }),
              installation.availability != .ready || installation.deletionPending
            {
              throw MoxError(.invalidModel, "Managed model is unavailable; inspect or remove the installation.")
            }
            submittingPaths.insert(normalized)
            defer { submittingPaths.remove(normalized) }
            try await runtime.load(model: LocalModel(path: normalized))
          case "unload":
            guard !submittingPaths.contains(normalized) else {
              throw MoxError(.busy, "Model request is starting.")
            }
            removingPaths.insert(normalized)
            defer { removingPaths.remove(normalized) }
            try await runtime.unload(modelID: LocalModelIdentity.identifier(for: URL(fileURLWithPath: normalized)))
          default: throw MoxError(.notFound, "Unknown model action.")
          }
          return try json(await snapshot())
        }
      }
      if request.method == .delete, path.hasPrefix("/mox/v1/models/") {
        guard let downloads, let id = UUID(uuidString: String(path.dropFirst("/mox/v1/models/".count))) else {
          throw MoxError(.notFound, "Model installation was not found.")
        }
        let item = try await downloads.installation(id)
        let normalized = URL(fileURLWithPath: item.path).standardizedFileURL.resolvingSymlinksInPath().path
        guard !removingPaths.contains(normalized), !submittingPaths.contains(normalized) else {
          throw MoxError(.busy, "Model has a request starting or removal in progress.")
        }
        removingPaths.insert(normalized)
        defer { removingPaths.remove(normalized) }
        try await runtime.unload(modelID: LocalModelIdentity.identifier(for: URL(fileURLWithPath: normalized)))
        try await downloads.removeInstallation(id)
        return try json(ModelLibraryPage(await downloads.snapshot()))
      }
      if request.method == .post, path == "/mox/v1/downloads" || path == "/mox/v1/downloads/plan" {
        guard let downloads, let sources else { throw MoxError(.shuttingDown, "Model downloads are unavailable.") }
        if let length = request.headers[.contentLength].flatMap(Int.init), length > 16_384 {
          throw MoxError(.bodyTooLarge, "Download request exceeds 16 KiB.")
        }
        var data = Data()
        for try await buffer in request.body {
          guard buffer.readableBytes <= 16_384 - data.count else {
            throw MoxError(.bodyTooLarge, "Download request exceeds 16 KiB.")
          }
          data.append(contentsOf: buffer.readableBytesView)
        }
        let body = try Wire.decode(PullBody.self, data)
        let (source, manifest, endpoint) = try await resolvePull(body, downloads: downloads, sources: sources)
        if path == "/mox/v1/downloads/plan" {
          return try json(ModelDownloadPlanSummary(try await downloads.plan(manifest)))
        }
        let id = try await downloads.create(
          provider: body.provider, endpoint: endpoint, manifest: manifest)
        try await downloads.resume(id, source: source)
        return try json(DownloadCreated(id: id), status: .accepted)
      }
      let downloadParts = path.split(separator: "/")
      if request.method == .get, downloadParts.count == 4,
        downloadParts.prefix(3).joined(separator: "/") == "mox/v1/downloads",
        let id = UUID(uuidString: String(downloadParts[3])), let downloads
      {
        guard let item = await downloads.snapshot().operations.first(where: { $0.id == id }) else {
          throw MoxError(.notFound, "Download operation was not found.")
        }
        return try json(DownloadOperationSummary(item))
      }
      if request.method == .post, downloadParts.count == 5,
        downloadParts.prefix(3).joined(separator: "/") == "mox/v1/downloads",
        let id = UUID(uuidString: String(downloadParts[3])), let downloads, let sources
      {
        switch downloadParts[4] {
        case "pause": try await downloads.pause(id)
        case "cancel": try await downloads.cancel(id)
        case "discard": try await downloads.discard(id)
        case "resume":
          guard let operation = await downloads.snapshot().operations.first(where: { $0.id == id }) else {
            throw MoxError(.notFound, "Download operation was not found.")
          }
          let registry = try await downloads.registry(operation.manifest.origin.registryID)
          let reference = try registry.credentialReference(for: operation.endpoint)
          let source = try sources.make(
            provider: operation.provider, endpoint: operation.endpoint, credentialReference: reference)
          try await downloads.resume(id, source: source)
        default: throw MoxError(.notFound, "Unknown download action.")
        }
        return try json(ModelLibraryPage(await downloads.snapshot()))
      }
      if request.method == .post, path == "/mox/v1/generations" {
        if let length = request.headers[.contentLength].flatMap(Int.init), length > Wire.bodyLimit {
          return error(
            MoxError(.bodyTooLarge, "Request exceeds 16 MiB."), status: .contentTooLarge,
            closing: context.channel)
        }
        var data = Data()
        for try await buffer in request.body {
          guard buffer.readableBytes <= Wire.bodyLimit - data.count else {
            return error(
              MoxError(.bodyTooLarge, "Request exceeds 16 MiB."), status: .contentTooLarge,
              closing: context.channel)
          }
          data.append(contentsOf: buffer.readableBytesView)
        }
        let body: GenerateBody
        do { body = try GenerateBody.decode(data) } catch let e as MoxError { throw e } catch {
          throw MoxError(.invalidParameters, "Invalid generation JSON.")
        }
        let handle = try await begin(body)
        let channel = context.channel
        channel.closeFuture.whenComplete { _ in handle.cancel() }
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
    } catch let e as MoxError { return error(e) } catch {
      return self.error(
        MoxError(.generationFailed, "Service operation failed; inspect diagnostics."))
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
    let code: HTTPResponse.Status =
      status
      ?? {
        switch value.code {
        case .authenticationFailed: .unauthorized
        case .notFound: .notFound
        case .busy, .serviceConflict: .conflict
        case .bodyTooLarge: .contentTooLarge
        case .queueFull, .queueTimeout: .tooManyRequests
        case .resourceLimit, .shuttingDown: .serviceUnavailable
        case .loadFailed, .generationFailed: .internalServerError
        default: .badRequest
        }
      }()
    var response =
      (try? json(ErrorEnvelope(instanceID: identity.instanceID, error: value), status: code))
      ?? Response(status: .internalServerError)
    if let channel {
      response.headers[.connection] = "close"
      let bytes =
        (try? Wire.encode(ErrorEnvelope(instanceID: identity.instanceID, error: value))) ?? Data()
      response.body = ResponseBody { writer in
        try await writer.write(ByteBuffer(bytes: bytes))
        try await writer.finish(nil)
        // Explicit close prevents Hummingbird's keepalive loop draining an unlimited body.
        channel.close(mode: .all, promise: nil)
      }
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
      configuration: .init(
        address: .hostname("127.0.0.1", port: 0), serverName: "Mox",
        availableConnectionsDelegate: MaximumAvailableConnections(ServiceCapacity.connections)),
      onServerRunning: { channel in
        if let port = channel.localAddress?.port { await onReady(port) }
      })
    try await app.run()
  }
}
