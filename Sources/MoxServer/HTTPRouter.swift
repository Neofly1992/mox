import Foundation
import MoxShared
import NIOCore
import NIOHTTP1

/// v0.8 — single dispatch table for every HTTP route. Adding a new
/// endpoint is one line in `routes`; no edits to the per-method
/// switch. The router falls through to `notFound` on no-match, which
/// matches the previous behaviour.
enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Endpoint descriptor. New endpoint families (rerank, count_tokens,
/// image gen) add a single case here and a handler in the dispatcher.
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

// MARK: - JSON response envelope

/// v0.8 — single error-envelope type. Replaces the previous
/// independent `ErrorBody` and `AnthropicErrorResponse.ErrorBody`
/// types. The OpenAI wire shape is `{"error":{"message","type",
/// "code"}}`; the Anthropic wire shape is `{"type":"error","error":
/// {"type","message"}}`. Both use the same `ErrorBody` for the inner
/// fields; the wrapping envelope is selected at the call site.
struct ErrorBody: Codable, Sendable {
    public let message: String
    public let type: String
    public let code: String?
}

struct ErrorPayload: Codable, Sendable {
    public let error: ErrorBody
}

/// v0.8 — consolidated JSON response writer. Replaces the previous
/// `respond(on:)` and `respondAnthropicJSON(on:)` pair (90%
/// duplicated). Anthropic callers pass `extraHeaders: ["anthropic-version":
/// "2023-06-01"]`; OpenAI callers leave it empty.
enum JSONResponse {
    static func write<Payload: Encodable>(
        _ payload: Payload,
        status: HTTPResponseStatus = .ok,
        extraHeaders: [String: String] = [:],
        on channel: Channel
    ) {
        let body: ByteBuffer
        do {
            let data = try JSONEncoder().encode(payload)
            body = channel.allocator.buffer(bytes: data)
        } catch {
            // Encoding failure on a Codable value we just built is
            // a programmer error; surface as 500 with a structured
            // body. Don't recurse into write().
            let errBody = ErrorPayload(error: ErrorBody(
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
                ErrorPayload(error: ErrorBody(
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

    /// Convenience: emit a 501 Not Implemented response with a
    /// structured envelope. Used by endpoints whose wire contract
    /// is shipped but the inference actor is not (e.g. v0.8
    /// `/v1/embeddings`).
    static func writeNotImplemented<Payload: Encodable>(
        _ payload: Payload,
        extraHeaders: [String: String] = [:],
        on channel: Channel
    ) {
        write(
            payload,
            status: HTTPResponseStatus(statusCode: 501, reasonPhrase: "Not Implemented"),
            extraHeaders: extraHeaders,
            on: channel
        )
    }

    enum ErrorKind {
        case openAI
        case anthropic
    }
}