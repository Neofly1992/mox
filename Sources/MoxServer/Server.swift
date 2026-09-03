import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import MoxCore
import MoxShared
import os

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

        // Capture pipeline-installation failures. The previous version used
        // `flatMap` chains that silently dropped EventLoopFuture failures,
        // leaving the channel open with no handlers installed. We surface
        // the error to the caller and tear the channel down.
        let pipelineFailure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                    channel.pipeline.addHandler(HTTPRequestAggregator())
                }.flatMap { _ in
                    channel.pipeline.addHandler(MoxHTTPHandler(host: self.host, port: self.port))
                }.flatMapError { error in
                    moxServerLog.error("pipeline install failed: \(String(describing: error), privacy: .public)")
                    pipelineFailure.withLock { $0 = error }
                    // Returning the close future so the channel shuts down
                    // immediately rather than hanging open with no handlers.
                    return channel.close()
                }
            }

        do {
            let channel = try bootstrap.bind(host: host, port: port).wait()
            if let installError = pipelineFailure.withLock({ $0 }) {
                try? channel.close().wait()
                throw installError
            }
            self.serverChannel = channel
            self.isRunning = true
            moxServerLog.info("server started on \(self.host, privacy: .public):\(self.port, privacy: .public)")
        } catch {
            moxServerLog.error("bind failed: \(String(describing: error), privacy: .public)")
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
    /// Bound host/port reported via `/health`. Captured at construction so
    /// the handler never reads mutable server state mid-request.
    private let host: String
    private let port: Int
    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
    /// Hard cap on POST body size. Localhost-only traffic is rare enough
    /// to exceed this accidentally; a 16 MiB cap is generous for any
    /// realistic chat completion body and prevents a single misbehaving
    /// client from OOMing the server.
    private static let maxBodyBytes = 16 * 1024 * 1024  // 16 MiB
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    /// While we wait on an async response
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
            if (self.bodyBuffer?.readableBytes ?? 0) + chunk.readableBytes > Self.maxBodyBytes {
                respond(
                    on: context.channel,
                    status: .payloadTooLarge,
                    payload: OpenAIErrorPayload(error: OpenAIErrorBody(
                        message: "Request body exceeds 16 MiB limit",
                        type: "invalid_request_error",
                        code: "request_too_large"
                    ))
                )
                self.head = nil
                self.bodyBuffer = nil
                return
            }
            self.bodyBuffer!.writeBuffer(&chunk)
        case .end:
            guard let head = self.head, let body = self.bodyBuffer else {
                respond(
                    on: context.channel,
                    status: .badRequest,
                    payload: OpenAIErrorPayload(error: OpenAIErrorBody(
                        message: "Malformed request: missing .head before .end",
                        type: "invalid_request_error",
                        code: "malformed_request"
                    ))
                )
                return
            }
            self.head = nil
            self.bodyBuffer = nil
            dispatch(context: context, head: head, body: body)
        }
    }

    private func dispatch(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        let channel = context.channel
        // v0.8 — table-driven routing. New endpoints add one line to
        // `HTTPRouter.routes`; no edits to this dispatch function.
        switch HTTPRouter.route(method: head.method.rawValue, path: head.uri) {
        case .health:
            handleHealth(channel: channel)
        case .listModels:
            handleListModels(channel: channel)
        case .chatCompletions:
            handleChatCompletion(channel: channel, body: body)
        case .legacyCompletions:
            handleCompletions(channel: channel, body: body)
        case .embeddings:
            handleEmbeddings(channel: channel, body: body)
        case .anthropicMessages:
            handleAnthropicMessages(channel: channel, body: body)
        case .notFound:
            JSONResponse.write(
                OpenAIErrorPayload(error: OpenAIErrorBody(
                    message: "Not found",
                    type: "invalid_request_error",
                    code: "not_found"
                )),
                status: .notFound,
                on: channel
            )
        }
    }

    private func handleListModels(channel: Channel) {
        // listModels is now async because ModelManager is an actor. Dispatch
        // the response on the channel's event loop after awaiting.
        Task {
            do {
                let models = try await ModelManager.shared.listModels()
                let items = models.map { info -> ModelItem in
                    ModelItem(
                        id: info.id,
                        name: info.name,
                        source: info.source.rawValue,
                        size: info.size
                    )
                }
                channel.eventLoop.execute {
                    JSONResponse.write(
                        ModelListResponse(object: "list", data: items),
                        on: channel
                    )
                }
            } catch {
                channel.eventLoop.execute {
                    JSONResponse.writeError(error, kind: .openAI, on: channel)
                }
            }
        }
    }

    private func handleHealth(channel: Channel) {
        let host = self.host
        let port = self.port
        Task {
            do {
                let loaded = await ModelRunner.shared.snapshotLoaded()
                let config = (try? await ConfigManager.shared.load()) ?? AppConfig()
                let sampler = config.defaults
                let models = loaded.map { rec in
                    HealthPayload.ModelCapability(
                        id: rec.id,
                        family: rec.modelFamily,
                        loaded: true,
                        supportsToolCalls: rec.supportsToolCalls,
                        contextWindow: rec.contextWindow,
                        warmupTokens: rec.warmupTokens,
                        compatibility: rec.compatibility?.rawValue,
                        compatibilityReason: rec.compatibilityReason
                    )
                }
                // v0.8.6+ — pull the registry's view of the resident
                // set so /health shows the budget the LRU policy
                // is enforcing. nil when no model has been loaded
                // yet on this runner.
                let registrySnap = await ModelRunner.shared.registrySnapshot()
                let payload = HealthPayload(
                    status: "ok",
                    moxVersion: moxHealthPayloadVersion,
                    serverVersion: moxHealthPayloadVersion,
                    models: models,
                    capabilities: .v07,
                    samplerDefaults: SamplerDefaults(
                        temperature: sampler.temperature,
                        topP: sampler.topP,
                        maxTokens: sampler.maxTokens
                    ),
                    runtime: HealthPayload.Runtime(
                        host: host,
                        port: port,
                        maxBodyBytes: 16 * 1024 * 1024,
                        cacheBudgetBytes: registrySnap?.cacheBudgetBytes,
                        cacheUsedBytes: registrySnap?.cacheUsedBytes,
                        loadedModelCount: registrySnap?.entries.count ?? loaded.count
                    )
                )
                channel.eventLoop.execute {
                    self.respond(on: channel, status: .ok, payload: payload)
                }
            } catch {
                channel.eventLoop.execute {
                    self.respondError(on: channel, error: error)
                }
            }
        }
    }



    private func handleCompletions(channel: Channel, body: ByteBuffer) {
        let bodyData = Data(body.readableBytesView)
        let raw: CompletionRequest
        do {
            raw = try JSONDecoder().decode(CompletionRequest.self, from: bodyData)
        } catch {
            respondError(on: channel, error: error)
            return
        }
        let resolved: ResolvedRequest
        do {
            resolved = try RequestPolicy.resolve(ResolutionInput(
                model: raw.model,
                prompt: raw.prompt,
                rawTemperature: raw.temperature,
                rawTopP: raw.topP,
                rawStream: raw.stream
            ))
        } catch {
            respondError(on: channel, error: error)
            return
        }
        if resolved.sampler.stream {
            handleCompletionsStream(channel: channel, resolved: resolved, raw: raw)
            return
        }
        let includeUsage = raw.streamOptions?.includeUsage ?? false
        let promptTokenEstimate = max(1, resolved.messages.reduce(0) { $0 + $1.content.count } / 4)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        let task = Task {
            do {
                let response = try await ModelRunner.shared.chat(
                    modelId: resolved.model,
                    messages: resolved.messages,
                    maxTokens: resolved.sampler.maxTokens,
                    temperature: resolved.sampler.temperature.value,
                    topP: resolved.sampler.topP.value
                )
                let text = response.choices.first?.message.content ?? ""
                let completionTokens = max(1, text.count / 4)
                let payload = CompletionResponse(
                    id: "cmpl-\(UUID().uuidString.prefix(8))",
                    created: Int64(Date().timeIntervalSince1970),
                    model: resolved.model,
                    choices: [
                        CompletionResponse.Choice(index: 0, text: text, finishReason: "stop")
                    ],
                    usage: ChatCompletionResponse.Usage(
                        promptTokens: promptTokenEstimate,
                        completionTokens: completionTokens,
                        totalTokens: promptTokenEstimate + completionTokens
                    )
                )
                _ = includeUsage
                channel.eventLoop.execute {
                    self.respond(on: channel, status: .ok, payload: payload)
                }
            } catch {
                channel.eventLoop.execute {
                    self.respondError(on: channel, error: error)
                }
            }
        }
        self.pendingTask = task
    }

    private func handleCompletionsStream(channel: Channel, resolved: ResolvedRequest, raw: CompletionRequest) {
        let modelId = resolved.model
        let completionId = "cmpl-\(UUID().uuidString.prefix(8))"
        let created = Int64(Date().timeIntervalSince1970)
        let includeUsage = raw.streamOptions?.includeUsage ?? false
        let promptTokenEstimate = max(1, resolved.messages.reduce(0) { $0 + $1.content.count } / 4)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        channel.eventLoop.execute {
            self.beginOpenAISSE(channel: channel)
        }
        let task = Task { [self] in
            do {
                let stream = try await ModelRunner.shared.chatStream(
                    modelId: modelId,
                    messages: resolved.messages,
                    maxTokens: resolved.sampler.maxTokens,
                    temperature: resolved.sampler.temperature.value,
                    topP: resolved.sampler.topP.value
                )
                var fullText = ""
                for try await piece in stream {
                    fullText += piece
                    let chunk = CompletionChunk(
                        id: completionId,
                        created: created,
                        model: modelId,
                        choices: [
                            CompletionChunk.Choice(
                                index: 0,
                                text: piece,
                                finishReason: nil
                            )
                        ]
                    )
                    self.writeCompletionChunk(chunk, on: channel)
                }
                let completionTokens = max(1, fullText.count / 4)
                if includeUsage {
                    let usageChunk = CompletionChunk(
                        id: completionId,
                        created: created,
                        model: modelId,
                        choices: [
                            CompletionChunk.Choice(index: 0, text: "", finishReason: nil)
                        ],
                        usage: ChatCompletionChunk.Usage(
                            promptTokens: promptTokenEstimate,
                            completionTokens: completionTokens,
                            totalTokens: promptTokenEstimate + completionTokens
                        )
                    )
                    self.writeCompletionChunk(usageChunk, on: channel)
                }
                let stopChunk = CompletionChunk(
                    id: completionId,
                    created: created,
                    model: modelId,
                    choices: [
                        CompletionChunk.Choice(index: 0, text: "", finishReason: "stop")
                    ]
                )
                self.writeCompletionChunk(stopChunk, on: channel)
                channel.eventLoop.execute {
                    self.endOpenAISSE(channel: channel)
                }
            } catch {
                let errJSON = #"{"error":{"message":"\#(error)","type":"server_error"}}"#
                channel.eventLoop.execute {
                    self.writeOpenAISSE(channel: channel, data: errJSON)
                    self.endOpenAISSE(channel: channel)
                }
            }
        }
        self.pendingTask = task
    }

    private func writeCompletionChunk(_ chunk: CompletionChunk, on channel: Channel) {
        guard let data = try? JSONEncoder().encode(chunk),
              let str = String(data: data, encoding: .utf8) else { return }
        channel.eventLoop.execute {
            self.writeOpenAISSE(channel: channel, data: str)
        }
    }

    private func handleEmbeddings(channel: Channel, body: ByteBuffer) {
        let bodyData = Data(body.readableBytesView)
        guard let _ = try? JSONDecoder().decode(EmbeddingRequest.self, from: bodyData) else {
            respondError(on: channel, error: MoxError.invalidModelId("(unparseable body)"))
            return
        }
        // v0.8 ships the wire contract; the inference actor lands in v0.9.
        // Returning a structured 501 so client SDKs can branch on it.
        respond(
            on: channel,
            status: HTTPResponseStatus(
                statusCode: 501,
                reasonPhrase: "Not Implemented"
            ),
            payload: EmbeddingNotImplementedError(error: EmbeddingNotImplementedError.notImplemented)
        )
    }

    private func handleChatCompletion(channel: Channel, body: ByteBuffer) {
        let bodyData = Data(body.readableBytesView)
        let raw: ChatCompletionRequest
        do {
            raw = try JSONDecoder().decode(ChatCompletionRequest.self, from: bodyData)
        } catch {
            respondError(on: channel, error: error)
            return
        }
        let resolved: ResolvedRequest
        do {
            resolved = try RequestPolicy.resolve(ResolutionInput(
                model: raw.model,
                messages: raw.messages,
                rawTemperature: raw.temperature,
                rawTopP: raw.topP,
                rawStream: raw.stream,
                rawTools: raw.tools ?? []
            ))
        } catch {
            respondError(on: channel, error: error)
            return
        }
        if resolved.sampler.stream {
            handleOpenAIStream(channel: channel, resolved: resolved, raw: raw)
            return
        }

        let runner = ModelRunner.shared
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        let task = Task {
            do {
                var response = try await runner.chat(
                    modelId: resolved.model,
                    messages: resolved.messages,
                    maxTokens: resolved.sampler.maxTokens,
                    temperature: resolved.sampler.temperature.value,
                    topP: resolved.sampler.topP.value
                )
                if !resolved.tools.isEmpty {
                    let familyHint = await runner.modelFamilyHint(for: resolved.model)
                    let parser = ToolCallParserRegistry.parser(forFamily: familyHint)
                    let parsed = parser.parse(text: response.choices.first?.message.content ?? "")
                    if !parsed.toolCalls.isEmpty {
                        let toolCalls = parsed.toolCalls.enumerated().map { (idx, call) in
                            OpenAIToolCall(
                                index: idx,
                                id: call.id,
                                type: "function",
                                function: .init(name: call.name, arguments: call.arguments)
                            )
                        }
                        response = ChatCompletionResponse(
                            id: response.id,
                            created: response.created,
                            model: response.model,
                            choices: [
                                ChatCompletionResponse.Choice(
                                    index: 0,
                                    message: ChatCompletionResponse.AssistantMessage(
                                        role: "assistant",
                                        content: parsed.visibleText,
                                        toolCalls: toolCalls
                                    ),
                                    finishReason: "tool_calls"
                                )
                            ],
                            usage: response.usage
                        )
                    }
                }
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

    /// OpenAI streaming chat completion. Emits SSE `data: <ChatCompletionChunk>`
    /// lines and a terminating `data: [DONE]`. Mirrors the wire format
    /// `mox ask --stream` produces so the same client parser works for
    /// both the daemon and the ephemeral backend.
    private func handleOpenAIStream(channel: Channel, resolved: ResolvedRequest, raw: ChatCompletionRequest) {
        let modelId = resolved.model
        let completionId = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int64(Date().timeIntervalSince1970)
        let includeUsage = raw.streamOptions?.includeUsage ?? false
        let promptTokenEstimate = max(1, resolved.messages.reduce(0) { $0 + $1.content.count } / 4)

        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise

        channel.eventLoop.execute {
            self.beginOpenAISSE(channel: channel)
        }

        let task = Task { [self] in
            // First chunk announces the role (OpenAI convention).
            let roleChunk = ChatCompletionChunk(
                id: completionId,
                object: "chat.completion.chunk",
                created: created,
                model: modelId,
                choices: [
                    ChatCompletionChunk.Choice(
                        index: 0,
                        delta: ChatCompletionChunk.Delta(role: "assistant", content: ""),
                        finishReason: nil
                    )
                ]
            )
            self.writeChunk(roleChunk, on: channel)

            do {
                let stream = try await ModelRunner.shared.chatStream(
                    modelId: modelId,
                    messages: resolved.messages,
                    maxTokens: resolved.sampler.maxTokens,
                    temperature: resolved.sampler.temperature.value,
                    topP: resolved.sampler.topP.value
                )
                var fullText = ""
                for try await piece in stream {
                    fullText += piece
                    let chunk = ChatCompletionChunk(
                        id: completionId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: modelId,
                        choices: [
                            ChatCompletionChunk.Choice(
                                index: 0,
                                delta: ChatCompletionChunk.Delta(role: nil, content: piece),
                                finishReason: nil
                            )
                        ]
                    )
                    self.writeChunk(chunk, on: channel)
                }
                let completionTokens = max(1, fullText.count / 4)
                // Optional trailing usage chunk when client opted in.
                if includeUsage {
                    let usageChunk = ChatCompletionChunk(
                        id: completionId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: modelId,
                        choices: [
                            ChatCompletionChunk.Choice(
                                index: 0,
                                delta: ChatCompletionChunk.Delta(role: nil, content: ""),
                                finishReason: nil
                            )
                        ],
                        usage: ChatCompletionChunk.Usage(
                            promptTokens: promptTokenEstimate,
                            completionTokens: completionTokens,
                            totalTokens: promptTokenEstimate + completionTokens
                        )
                    )
                    self.writeChunk(usageChunk, on: channel)
                }
                // Terminator chunk — `finish_reason: "stop"`, empty delta.
                let stopChunk = ChatCompletionChunk(
                    id: completionId,
                    object: "chat.completion.chunk",
                    created: created,
                    model: modelId,
                    choices: [
                        ChatCompletionChunk.Choice(
                            index: 0,
                            delta: ChatCompletionChunk.Delta(role: nil, content: ""),
                            finishReason: "stop"
                        )
                    ]
                )
                self.writeChunk(stopChunk, on: channel)
                channel.eventLoop.execute {
                    self.endOpenAISSE(channel: channel)
                }
            } catch {
                let errJSON = #"{"error":{"message":"\#(error)","type":"server_error"}}"#
                channel.eventLoop.execute {
                    self.writeOpenAISSE(channel: channel, data: errJSON)
                    self.endOpenAISSE(channel: channel)
                }
            }
        }
        self.pendingTask = task
    }

    private func writeChunk(_ chunk: ChatCompletionChunk, on channel: Channel) {
        guard let data = try? JSONEncoder().encode(chunk),
              let str = String(data: data, encoding: .utf8) else { return }
        channel.eventLoop.execute {
            self.writeOpenAISSE(channel: channel, data: str)
        }
    }


    /// Thin shim around `JSONResponse.write` for callers that still use
    /// the old method-call style. v0.8 — kept for the two
    /// `bodyTooLarge` / `malformedRequest` early-exit paths in
    /// `channelRead`; new code should call `JSONResponse.write`
    /// directly.
    private func respond<Payload: Encodable>(
        on channel: Channel,
        status: HTTPResponseStatus,
        payload: Payload
    ) {
        JSONResponse.write(payload, status: status, on: channel)
    }
    /// Handle `POST /v1/messages`. Decodes an `AnthropicMessagesRequest`,
    /// rejects `tools` with 400 (not supported in v0.4.1), and either
    /// returns a JSON response or streams Anthropic SSE events
    /// (`message_start` → `content_block_start` → `content_block_delta` →
    /// `content_block_stop` → `message_delta` → `message_stop`).
    private func handleAnthropicMessages(channel: Channel, body: ByteBuffer) {
        let bodyData = Data(body.readableBytesView)
        let request: AnthropicMessagesRequest
        do {
            request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: bodyData)
        } catch {
            respondAnthropicError(on: channel,
                status: .badRequest,
                type: "invalid_request_error",
                message: "Malformed JSON: \(error.localizedDescription)")
            return
        }

        // v0.7 refuses tools — return structured 400 so callers can adapt.
        if let tools = request.tools, !tools.isEmpty {
            respondAnthropicError(on: channel,
                status: .badRequest,
                type: "invalid_request_error",
                message: "tools are not supported in this Mox build (v0.7)")
            return
        }

        // Translate Anthropic messages into Mox internal ChatMessage list.
        var messages: [ChatMessage] = []
        if let system = request.system?.flattenedText, !system.isEmpty {
            messages.append(ChatMessage(role: "system", content: system))
        }
        for m in request.messages {
            let text = m.content.flattenedText
            if text.isEmpty { continue }
            messages.append(ChatMessage(role: m.role.lowercased(), content: text))
        }

        let resolved: ResolvedRequest
        do {
            resolved = try RequestPolicy.resolve(ResolutionInput(
                model: request.model,
                messages: messages,
                rawTemperature: request.temperature,
                rawTopP: request.topP,
                rawStream: request.stream
            ))
        } catch {
            respondAnthropicError(on: channel,
                status: .badRequest,
                type: "invalid_request_error",
                message: error.localizedDescription)
            return
        }

        if request.stream == true {
            handleAnthropicStream(
                channel: channel,
                request: request,
                resolved: resolved
            )
        } else {
            handleAnthropicNonStream(
                channel: channel,
                request: request,
                resolved: resolved
            )
        }
    }
    private func handleAnthropicNonStream(
        channel: Channel,
        request: AnthropicMessagesRequest,
        resolved: ResolvedRequest
    ) {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        let task = Task {
            do {
                let response = try await ModelRunner.shared.chat(
                    modelId: resolved.model,
                    messages: resolved.messages,
                    maxTokens: resolved.sampler.maxTokens,
                    temperature: resolved.sampler.temperature.value,
                    topP: resolved.sampler.topP.value
                )
                let payload = AnthropicMessagesResponse(
                    id: "msg_\(UUID().uuidString.prefix(24))",
                    content: [.text(response.choices.first?.message.content ?? "")],
                    model: resolved.model,
                    stopReason: "end_turn",
                    usage: AnthropicUsage(
                        inputTokens: response.usage.promptTokens,
                        outputTokens: response.usage.completionTokens
                    )
                )
                channel.eventLoop.execute {
                    self.respondAnthropicJSON(on: channel, status: .ok, payload: payload)
                }
            } catch {
                channel.eventLoop.execute {
                    self.respondAnthropicError(on: channel,
                        status: .internalServerError,
                        type: "api_error",
                        message: error.localizedDescription)
                }
            }
        }
        self.pendingTask = task
    }

    private func handleAnthropicStream(
        channel: Channel,
        request: AnthropicMessagesRequest,
        resolved: ResolvedRequest
    ) {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        self.pendingResponse = promise
        let task = Task {
            // Switch to SSE: write response headers immediately, then keep
            // writing events as tokens arrive.
            channel.eventLoop.execute {
                self.beginAnthropicSSE(channel: channel, model: resolved.model)
            }

            let messageId = "msg_\(UUID().uuidString.prefix(24))"
            var emittedStart = false
            var fullText = ""
            let stream = await ModelRunner.shared.chatStream(
                modelId: resolved.model,
                messages: resolved.messages,
                maxTokens: resolved.sampler.maxTokens,
                temperature: resolved.sampler.temperature.value,
                topP: resolved.sampler.topP.value
            )
            do {
                for try await chunk in stream {
                    if !emittedStart {
                        channel.eventLoop.execute {
                            self.writeAnthropicSSE(channel: channel, event: "message_start", data: [
                                "type": AnyCodable.string("message_start"),
                                "message": AnyCodable.object([
                                    "id": AnyCodable.string(messageId),
                                    "type": AnyCodable.string("message"),
                                    "role": AnyCodable.string("assistant"),
                                    "model": AnyCodable.string(resolved.model),
                                    "stop_reason": AnyCodable.null,
                                    "stop_sequence": AnyCodable.null,
                                    "usage": AnyCodable.object(["input_tokens": .int(0), "output_tokens": .int(0)])
                                ])
                            ])
                            self.writeAnthropicSSE(channel: channel, event: "content_block_start", data: [
                                "type": AnyCodable.string("content_block_start"),
                                "index": AnyCodable.int(0),
                                "content_block": AnyCodable.object([
                                    "type": AnyCodable.string("text"),
                                    "text": AnyCodable.string("")
                                ])
                            ])
                            self.writeAnthropicSSE(channel: channel, event: "ping", data: [
                                "type": AnyCodable.string("ping")
                            ])
                        }
                    }
                    fullText += chunk
                    channel.eventLoop.execute {
                        self.writeAnthropicSSE(channel: channel, event: "content_block_delta", data: [
                            "type": AnyCodable.string("content_block_delta"),
                            "index": AnyCodable.int(0),
                            "delta": AnyCodable.object([
                                "type": AnyCodable.string("text_delta"),
                                "text": AnyCodable.string(chunk)
                            ])
                        ])
                    }
                }
                let outputTokens = max(1, fullText.count / 4)
                channel.eventLoop.execute {
                    self.writeAnthropicSSE(channel: channel, event: "content_block_stop", data: [
                        "type": AnyCodable.string("content_block_stop"),
                        "index": AnyCodable.int(0)
                    ])
                    self.writeAnthropicSSE(channel: channel, event: "message_delta", data: [
                        "type": AnyCodable.string("message_delta"),
                        "delta": AnyCodable.object([
                            "stop_reason": AnyCodable.string("end_turn"),
                            "stop_sequence": AnyCodable.null
                        ]),
                        "usage": AnyCodable.object([
                            "output_tokens": AnyCodable.int(outputTokens)
                        ])
                    ])
                    self.writeAnthropicSSE(channel: channel, event: "message_stop", data: [
                        "type": AnyCodable.string("message_stop")
                    ])
                    self.endAnthropicSSE(channel: channel)
                }
            } catch {
                // Per Anthropic spec, mid-stream errors must emit
                // `event: error` before the terminating `message_stop`.
                channel.eventLoop.execute {
                    self.writeAnthropicSSE(channel: channel, event: "error", data: [
                        "type": AnyCodable.string("error"),
                        "error": AnyCodable.object([
                            "type": AnyCodable.string("invalid_request_error"),
                            "message": AnyCodable.string("\(error)"),
                        ])
                    ])
                    self.writeAnthropicSSE(channel: channel, event: "message_stop", data: [
                        "type": AnyCodable.string("message_stop")
                    ])
                    self.endAnthropicSSE(channel: channel)
                }
            }
        }
        self.pendingTask = task
    }


    // MARK: Anthropic response helpers

    private func beginAnthropicSSE(channel: Channel, model: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "anthropic-version", value: "2023-06-01")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        channel.write(HTTPServerResponsePart.head(head)).whenComplete { _ in }
    }

    private func writeAnthropicSSE(channel: Channel, event: String, data: [String: AnyCodable]) {
        // SSE: `event: <name>\ndata: <json>\n\n`.
        let payload: String
        if let data = try? JSONEncoder().encode(AnyCodable.object(data)),
           let str = String(data: data, encoding: .utf8) {
            payload = str
        } else {
            payload = "{}"
        }
        let bytes = "event: \(event)\ndata: \(payload)\n\n"
        var buf = channel.allocator.buffer(capacity: bytes.utf8.count)
        buf.writeString(bytes)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf))).whenComplete { _ in }
        channel.flush()
    }

    // MARK: OpenAI SSE response helpers

    private func beginOpenAISSE(channel: Channel) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        // OpenAI uses the same wire format as the OpenAI Python SDK: each
        // chunk is `data: <json>\n\n` and the stream terminates with
        // `data: [DONE]\n\n`. No `event:` field.
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        channel.write(HTTPServerResponsePart.head(head)).whenComplete { _ in }
    }

    private func writeOpenAISSE(channel: Channel, data: String) {
        let bytes = "data: \(data)\n\n"
        var buf = channel.allocator.buffer(capacity: bytes.utf8.count)
        buf.writeString(bytes)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf))).whenComplete { _ in }
        channel.flush()
    }

    private func endOpenAISSE(channel: Channel) {
        let bytes = "data: [DONE]\n\n"
        var buf = channel.allocator.buffer(capacity: bytes.utf8.count)
        buf.writeString(bytes)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf))).whenComplete { _ in }
    }

    private func finishPending() {
        if let promise = pendingResponse {
            promise.succeed(())
            pendingResponse = nil
        }
    }


    private func endAnthropicSSE(channel: Channel) {
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in }
        finishPending()
    }

    /// Thin shim around `JSONResponse.write` for the Anthropic JSON
    /// envelope. v0.8 — pre-aggregates the `anthropic-version` header.
    private func respondAnthropicJSON<Payload: Encodable>(
        on channel: Channel,
        status: HTTPResponseStatus,
        payload: Payload
    ) {
        JSONResponse.write(
            payload,
            status: status,
            extraHeaders: ["anthropic-version": "2023-06-01"],
            on: channel
        )
    }

    /// Build an Anthropic-shaped error envelope and write it.
    private func respondAnthropicError(
        on channel: Channel,
        status: HTTPResponseStatus,
        type: String,
        message: String
    ) {
        let envelope = AnthropicErrorResponse(error: .init(type: type, message: message))
        JSONResponse.write(
            envelope,
            status: status,
            extraHeaders: ["anthropic-version": "2023-06-01"],
            on: channel
        )
    }

    private func respondError(on channel: Channel, error: Error) {
        JSONResponse.writeError(error, kind: .openAI, on: channel)
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



// MARK: - Errors

public enum HTTPError: Error, LocalizedError {
    case bindFailed

    public var errorDescription: String? {
        switch self {
        case .bindFailed: return "Failed to bind socket"
        }
    }
}

/// Wire shapes for the two error envelopes emitted by the
/// early-exit paths in `channelRead`. The main endpoints route
/// through `JSONResponse` for the happy path; these types exist
/// solely so the `payloadTooLarge` / `malformedRequest` branches
/// can hand a value to the `respond` shim.

