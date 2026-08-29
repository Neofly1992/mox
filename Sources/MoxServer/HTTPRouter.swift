import Foundation
import NIOCore
import MoxShared
import NIOHTTP1

/// v0.8 — single dispatch table for every HTTP route. New endpoints
/// add one line to `routes`; no edits to the per-method switch.
enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

enum HandlerKind: Sendable {
    case health
    case listModels
    case chatCompletions
    case legacyCompletions
    case embeddings
    case anthropicMessages
    case notFound
}

struct HTTPRoute: Sendable {
    let method: HTTPMethod
    let path: String
    let kind: HandlerKind
}

enum HTTPRouter {
    static let routes: [HTTPRoute] = [
        HTTPRoute(method: .get,  path: "/health",             kind: .health),
        HTTPRoute(method: .get,  path: "/v1/models",           kind: .listModels),
        HTTPRoute(method: .post, path: "/v1/chat/completions", kind: .chatCompletions),
        HTTPRoute(method: .post, path: "/v1/completions",      kind: .legacyCompletions),
        HTTPRoute(method: .post, path: "/v1/embeddings",       kind: .embeddings),
        HTTPRoute(method: .post, path: "/v1/messages",         kind: .anthropicMessages),
    ]

    static func route(method: String, path: String) -> HandlerKind {
        for route in routes where route.method.rawValue == method && route.path == path {
            return route.kind
        }
        return .notFound
    }
}

// MARK: - JSON response

/// v0.8 — single JSON response writer that handles both happy-path
/// `Encodable` payloads and structured errors. Replaces the previous
/// `respond(on:)` + `respondAnthropicJSON(on:)` pair (90% duplicated)
/// + `respondError(on:)` + `respondAnthropicError(on:)` quartet.
enum JSONResponse {
    static func write<Payload: Encodable>(
        _ payload: Payload,
        status: HTTPResponseStatus = .ok,
        extraHeaders: [String: String] = [:],
        on channel: Channel
    ) {
        let body: ByteBuffer
        do {
            body = channel.allocator.buffer(bytes: try JSONEncoder().encode(payload))
        } catch {
            let errBody = OpenAIErrorPayload(error: OpenAIErrorBody(
                message: "internal: encode failure: \(error)",
                type: "server_error",
                code: "encode_failure"
            ))
            guard let errData = try? JSONEncoder().encode(errBody) else {
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in }
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(errData.count))
            for (k, v) in extraHeaders { headers.add(name: k, value: v) }
            let head = HTTPResponseHead(version: .http1_1, status: .internalServerError, headers: headers)
            channel.write(HTTPServerResponsePart.head(head)).whenComplete { _ in }
            channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: errData)))).whenComplete { _ in }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in }
            return
        }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        for (k, v) in extraHeaders { headers.add(name: k, value: v) }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head)).whenComplete { _ in }
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body))).whenComplete { _ in }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in }
    }

    /// Map a thrown error to the right envelope. `DecodingError`
    /// becomes 400; everything else becomes 500.
    static func writeError(
        _ error: Error,
        kind: ErrorKind,
        on channel: Channel
    ) {
        let isDecode = error is DecodingError
        let status: HTTPResponseStatus = isDecode ? .badRequest : .internalServerError
        switch kind {
        case .openAI:
            write(
                OpenAIErrorPayload(error: OpenAIErrorBody(
                    message: error.localizedDescription,
                    type: "server_error",
                    code: nil
                )),
                status: status,
                on: channel
            )
        case .anthropic:
            write(
                AnthropicErrorResponse(error: .init(
                    type: isDecode ? "invalid_request_error" : "api_error",
                    message: error.localizedDescription
                )),
                status: status,
                extraHeaders: ["anthropic-version": "2023-06-01"],
                on: channel
            )
        }
    }

    enum ErrorKind {
        case openAI
        case anthropic
    }
}