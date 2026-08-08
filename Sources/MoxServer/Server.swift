import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import MoxCore
import MoxShared

public final class MoxServer: @unchecked Sendable {
    public static let shared = MoxServer()

    private let host: String
    private let port: Int
    private let group: EventLoopGroup
    private var serverChannel: Channel?
    private let stateLock = NSLock()
    private var isRunning = false

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.host = host
        self.port = port
        self.group = group
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                    channel.pipeline.addHandler(HTTPRequestAggregator())
                }.flatMap { _ in
                    channel.pipeline.addHandler(MoxHTTPHandler())
                }
            }

        do {
            let channel = try bootstrap.bind(host: host, port: port).wait()
            self.serverChannel = channel
            self.isRunning = true
            print("Mox server started on http://\(host):\(port)")
        } catch {
            throw HTTPError.bindFailed
        }
    }

    public func stop() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = false
        let channel = serverChannel
        serverChannel = nil
        stateLock.unlock()

        if let channel = channel {
            try? channel.close().wait()
        }
        // Detached teardown of the event loop group so stop() stays non-async.
        Task.detached { [group] in
            try? await group.shutdownGracefully()
        }
    }
}

// MARK: - HTTP Request Aggregator

/// Aggregates HTTP request parts so downstream handlers see a single
/// `.head` → `.body(buffer)` → `.end(trailers)` triple per request. This is the
/// minimum we need to handle POST bodies correctly (the original implementation
/// truncated bodies > 16KB because it read once into a fixed buffer).
final class HTTPRequestAggregator: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    private var head: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var trailingHeaders: HTTPHeaders?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = Self.unwrapInboundIn(data)
        switch part {
        case .head(let h):
            // Defensive: if a prior request was buffered (shouldn't happen with
            // pipelining assistance, but be safe), forward it before starting fresh.
            flushPriorIfNeeded(context: context)
            self.head = h
            self.bodyBuffer = nil
            self.trailingHeaders = nil
        case .body(var chunk):
            if self.bodyBuffer == nil {
                self.bodyBuffer = context.channel.allocator.buffer(capacity: chunk.readableBytes)
            }
            self.bodyBuffer!.writeBuffer(&chunk)
        case .end(let trailers):
            self.trailingHeaders = trailers
            flushPriorIfNeeded(context: context)
        }
    }

    private func flushPriorIfNeeded(context: ChannelHandlerContext) {
        guard let head = self.head else { return }
        let body = self.bodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
        let trailers = self.trailingHeaders

        context.fireChannelRead(Self.wrapInboundOut(.head(head)))
        context.fireChannelRead(Self.wrapInboundOut(.body(body)))
        context.fireChannelRead(Self.wrapInboundOut(.end(trailers)))

        self.head = nil
        self.bodyBuffer = nil
        self.trailingHeaders = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        flushPriorIfNeeded(context: context)
        context.fireChannelInactive()
    }
}

// MARK: - HTTP Handler

/// Per-connection HTTP handler. Buffers the body of the current request, routes it,
/// and writes a structured JSON response. Keep-alive is handled by NIO's
/// `HTTPServerPipelineHandler` (which `configureHTTPServerPipeline` installs):
/// one request at a time, no `Connection: close` forced.
final class MoxHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// While we wait on an async response (e.g. chat completion), remember the
    /// promise so we can finish the pending pipeline handler bookkeeping once
    /// we send the response back. We also remember the in-flight Task so we
    /// can cancel its MLX work if the client disconnects mid-generation.
    private var pendingResponse: EventLoopPromise<Void>?
    private var pendingTask: Task<Void, Never>?
    private var bodyBuffer: ByteBuffer?
    private var head: HTTPRequestHead?
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = Self.unwrapInboundIn(data)
        switch part {
        case .head(let h):
            self.head = h
            self.bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            if self.bodyBuffer == nil {
                self.bodyBuffer = context.channel.allocator.buffer(capacity: chunk.readableBytes)
            }
            self.bodyBuffer!.writeBuffer(&chunk)
        case .end:
            guard let head = self.head, let body = self.bodyBuffer else {
                return
            }
            self.head = nil
            self.bodyBuffer = nil
            dispatch(context: context, head: head, body: body)
        }
    }

    // MARK: Routing

    private func dispatch(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        let channel = context.channel
        switch (head.method, head.uri) {
        case (.GET, "/health"):
            respond(on: channel, status: .ok, payload: HealthPayload(status: "ok"))

        case (.GET, "/v1/models"):
            handleListModels(channel: channel)

        case (.POST, "/v1/chat/completions"):
            handleChatCompletion(channel: channel, body: body)

        default:
            respond(
                on: channel,
                status: .notFound,
                payload: ErrorPayload(error: ErrorBody(
                    message: "Not found",
                    type: "invalid_request_error",
                    code: "not_found"
                ))
            )
        }
    }

    private func handleListModels(channel: Channel) {
        do {
            let models = try ModelManager.shared.listModels()
            let items = models.map { info -> ModelItem in
                ModelItem(
                    id: info.id,
                    name: info.name,
                    source: info.source.rawValue,
                    size: info.size
                )
            }
            respond(on: channel, status: .ok, payload: ModelListResponse(object: "list", data: items))
        } catch {
            respondError(on: channel, error: error)
        }
    }

    private func handleChatCompletion(channel: Channel, body: ByteBuffer) {
        let bodyData = Data(body.readableBytesView)
        let request: ChatCompletionRequest
        do {
            request = try JSONDecoder().decode(ChatCompletionRequest.self, from: bodyData)
        } catch {
            respondError(on: channel, error: error)
            return
        }

        let runner = ModelRunner.shared
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        let task = Task {
            do {
                let response = try await runner.chat(
                    modelId: request.model,
                    messages: request.messages,
                    maxTokens: request.maxTokens,
                    temperature: request.temperature,
                    topP: request.topP
                )
                channel.eventLoop.execute {
                    self.respond(on: channel, status: .ok, payload: response)
                }
            } catch {
                channel.eventLoop.execute {
                    self.respondError(on: channel, error: error)
                }
            }
        }
        self.pendingTask = task
    }

    /// Send a response using the `Channel` directly. Safe to invoke from a
    /// Sendable closure (e.g. after an async Task completes).
    private func respond<Payload: Encodable>(
        on channel: Channel,
        status: HTTPResponseStatus,
        payload: Payload
    ) {
        let encoder = JSONEncoder()
        let body: ByteBuffer
        do {
            let data = try encoder.encode(payload)
            body = channel.allocator.buffer(bytes: data)
        } catch {
            respondError(on: channel, error: error)
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.readableBytes))

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head)).whenComplete { _ in }
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body))).whenComplete { _ in }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in }
        finishPending()
    }

    private func respondError(on channel: Channel, error: Error) {
        let status: HTTPResponseStatus
        if error is DecodingError {
            status = .badRequest
        } else {
            status = .internalServerError
        }
        respond(
            on: channel,
            status: status,
            payload: ErrorPayload(error: ErrorBody(
                message: error.localizedDescription,
                type: "server_error",
                code: nil
            ))
        )
    }

    private func finishPending() {
        if let promise = pendingResponse {
            promise.succeed(())
            pendingResponse = nil
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let promise = pendingResponse {
            promise.fail(ChannelError.ioOnClosedChannel)
            pendingResponse = nil
        }
        if let task = pendingTask {
            task.cancel()
            pendingTask = nil
        }
        context.fireChannelInactive()
    }
}

private struct HealthPayload: Encodable {
    let status: String
}
private struct ModelItem: Encodable {
    let id: String
    let name: String
    let source: String
    let size: Int64
}

private struct ModelListResponse: Encodable {
    let object: String
    let data: [ModelItem]
}

private struct ErrorBody: Encodable {
    let message: String
    let type: String
    let code: String?
}

private struct ErrorPayload: Encodable {
    let error: ErrorBody
}

// MARK: - Errors

public enum HTTPError: Error, LocalizedError {
    case bindFailed

    public var errorDescription: String? {
        switch self {
        case .bindFailed: return "Failed to bind socket"
        }
    }
}
