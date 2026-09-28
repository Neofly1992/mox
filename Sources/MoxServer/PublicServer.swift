import Foundation
import Hummingbird
import HummingbirdCore
import MoxDomain
import MoxProtocol
import NIOCore

private enum PublicConnectionLimits {
  static let connections = 64
  static let idleTimeoutSeconds: Int64 = 15
  static let bodyReadDeadline: Duration = .seconds(15)
}

struct PublicServer: Sendable {
  let service: InferenceService
  let manager: PublicAPIManager
  func run(onReady: @escaping @Sendable (Int) async -> Void) async throws {
    let router = Router(context: ServiceContext.self)
    router.get("/**") { request, context in await response(request, context: context) }
    router.post("/**") { request, context in await response(request, context: context) }
    let app = Application(router: router,
      server: .http1(configuration: .init(idleTimeout: .seconds(PublicConnectionLimits.idleTimeoutSeconds))),
      configuration: .init(
      address: .hostname("127.0.0.1", port: 0), serverName: "Mox Public API",
      availableConnectionsDelegate: MaximumAvailableConnections(PublicConnectionLimits.connections)),
      onServerRunning: { channel in
        if let port = channel.localAddress?.port { await onReady(port) }
      })
    try await app.run()
  }
  private func response(_ request: Request, context: ServiceContext) async -> Response {
    let dialect: PublicDialect = request.uri.path == "/v1/messages" ? .anthropic : .openAI
    var bodyConsumed = false
    do {
      guard request.headers[.origin] == nil else {
        return failure(MoxError(.authenticationFailed, "Browser origins are not allowed."),
          dialect: dialect, status: .forbidden, closing: context.channel)
      }
      let authorization: String?
      if dialect == .anthropic { authorization = request.headers[.init("x-api-key")!] }
      else { authorization = request.headers[.authorization].flatMap {
        $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil
      } }
      guard await manager.authorize(authorization) else {
        return failure(MoxError(.authenticationFailed, "Public API authentication failed."),
          dialect: dialect, status: .unauthorized, closing: context.channel)
      }
      if request.method == .get,
        request.headers[.transferEncoding] != nil
          || (request.headers[.contentLength].flatMap(Int.init) ?? 0) > 0 {
        return failure(MoxError(.invalidParameters, "This endpoint requires an empty body."),
          dialect: dialect, closing: context.channel)
      }
      if request.uri.path == "/health", request.method == .get {
        return json(Data("{\"status\":\"ok\"}".utf8))
      }
      if request.uri.path == "/v1/models", request.method == .get {
        return json(try await service.publicModels())
      }
      guard request.method == .post,
        request.uri.path == "/v1/chat/completions" || request.uri.path == "/v1/messages" else {
        return failure(MoxError(.notFound, "Public endpoint not found."), dialect: dialect,
          status: .notFound, closing: context.channel)
      }
      guard request.headers[.contentType]?.lowercased().hasPrefix("application/json") == true else {
        throw MoxError(.invalidParameters, "Content-Type must be application/json.")
      }
      if dialect == .anthropic {
        guard request.headers[.init("anthropic-version")!] == "2023-06-01",
          request.headers[.init("anthropic-beta")!] == nil else {
          throw MoxError(.unsupportedInput, "Unsupported Anthropic version or beta header.")
        }
      }
      if let length = request.headers[.contentLength].flatMap(Int.init), length > Wire.bodyLimit {
        return failure(MoxError(.bodyTooLarge, "Request exceeds 16 MiB."), dialect: dialect,
          status: .contentTooLarge, closing: context.channel)
      }
      let channel = context.channel
      let bodyTimeout = Task {
        do { try await Task.sleep(for: PublicConnectionLimits.bodyReadDeadline) }
        catch { return }
        channel.close(mode: .all, promise: nil)
      }
      defer { bodyTimeout.cancel() }
      var data = Data()
      for try await buffer in request.body {
        guard buffer.readableBytes <= Wire.bodyLimit - data.count else {
          return failure(MoxError(.bodyTooLarge, "Request exceeds 16 MiB."), dialect: dialect,
            status: .contentTooLarge, closing: context.channel)
        }
        data.append(contentsOf: buffer.readableBytesView)
      }
      bodyConsumed = true
      bodyTimeout.cancel()
      let call = try PublicProtocol.parse(data, dialect: dialect)
      let handle = try await service.beginPublic(model: call.model, request: call.request)
      context.channel.closeFuture.whenComplete { [weak handle] _ in handle?.cancel() }
      if !call.stream {
        var encoder = PublicResponse(call: call)
        do {
          for await event in handle.events {
            await service.observePublic(event)
            _ = try encoder.accept(event)
          }
          await handle.waitUntilStopped()
          return json(try encoder.complete())
        } catch {
          handle.cancel()
          await handle.waitUntilStopped()
          for await event in handle.events { await service.observePublic(event) }
          throw error
        }
      }
      return Response(status: .ok, headers: [.contentType: "text/event-stream",
        .cacheControl: "no-store"], body: ResponseBody { writer in
        var encoder = PublicResponse(call: call)
        defer { handle.cancel() }
        var observedTerminal = false
        do {
          for await event in handle.events {
            await service.observePublic(event)
            observedTerminal = observedTerminal || event.payload.isTerminal
            let frames: [Data]
            do { frames = try encoder.accept(event) }
            catch let error as MoxError {
              let deadline = Task {
                try await Task.sleep(for: ServiceTiming.writeDeadline)
                try? await channel.close().get()
              }
              do { try await writer.write(ByteBuffer(bytes: PublicResponse.streamError(error, dialect: dialect))) }
              catch { deadline.cancel(); throw error }
              deadline.cancel()
              break
            }
            for frame in frames {
              let deadline = Task {
                try await Task.sleep(for: ServiceTiming.writeDeadline)
                try? await channel.close().get()
              }
              do { try await writer.write(ByteBuffer(bytes: frame)) }
              catch { deadline.cancel(); throw error }
              deadline.cancel()
            }
          }
          let deadline = Task {
            try await Task.sleep(for: ServiceTiming.writeDeadline)
            try? await channel.close().get()
          }
          do { try await writer.finish(nil) }
          catch { deadline.cancel(); throw error }
          deadline.cancel()
        } catch {
          handle.cancel()
        }
        await handle.waitUntilStopped()
        if !observedTerminal {
          for await event in handle.events { await service.observePublic(event) }
        }
      })
    } catch let error as MoxError {
      return failure(error, dialect: dialect, closing: bodyConsumed ? nil : context.channel)
    } catch {
      return failure(MoxError(.generationFailed, "Public API request failed; inspect diagnostics."),
        dialect: dialect, closing: bodyConsumed ? nil : context.channel)
    }
  }
  private func json(_ data: Data) -> Response {
    Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(bytes: data)))
  }
  private func failure(_ error: MoxError, dialect: PublicDialect,
    status: HTTPResponse.Status? = nil, closing channel: (any Channel)? = nil) -> Response {
    let status = status ?? {
      switch error.code {
      case .authenticationFailed: return HTTPResponse.Status.unauthorized
      case .notFound: return .notFound
      case .busy, .serviceConflict: return .conflict
      case .bodyTooLarge: return .contentTooLarge
      case .queueFull, .queueTimeout: return .tooManyRequests
      case .resourceLimit, .shuttingDown: return .serviceUnavailable
      case .loadFailed, .generationFailed: return .internalServerError
      default: return .badRequest
      }
    }()
    let bytes = PublicResponse.error(error, dialect: dialect)
    var response = Response(status: status,
      headers: [.contentType: "application/json", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    if let channel {
      response.headers[.connection] = "close"
      response.body = ResponseBody { writer in
        defer { channel.close(mode: .all, promise: nil) }
        try await writer.write(ByteBuffer(bytes: bytes))
        try await writer.finish(nil)
      }
    }
    return response
  }
}
