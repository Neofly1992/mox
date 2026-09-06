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
    case loadModel(id: String)
    case unloadModel(id: String)
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
        // v0.11 P1.2 — model load/unload. Path-param routes use a
        // synthetic kind (`{ id: String }`); the dispatch in
        // `Server.swift` switches on those kinds and routes the id
        // to the right handler. We don't try to encode the path
        // template in `HTTPRoute.path` because exact-match lookup
        // can't extract `{id}`.
        HTTPRoute(method: .post, path: "/v1/models/__id__/load", kind: .loadModel(id: "__id__")),
        HTTPRoute(method: .post, path: "/v1/models/__id__/unload", kind: .unloadModel(id: "__id__")),
    ]


    static func route(method: String, path: String) -> HandlerKind {
        let dbg = ProcessInfo.processInfo.environment["MOX_DEBUG_ROUTER"] != nil
        if dbg { print("[router] method=\(method) path=\(path)") }
        for route in routes where route.method.rawValue == method {
            // Path-param routes use `__id__` as a placeholder. The
            // `/v1/models/__id__/load` template matches any
            // `/v1/models/<id>/load` URI; we extract the id here
            // and surface it on the HandlerKind so the dispatch
            // in `Server.swift` can route by it.
            if let kind = matchPathParam(route: route, requestPath: path) {
                if dbg { print("[router] matched: \(kind)") }
                return kind
            }
        }
        return .notFound
    }

    /// Returns a HandlerKind (with the captured id baked in) if
    /// `route` is a path-param template and `requestPath` matches.
    /// Returns nil if no match (caller falls through to the next
    /// route, or to `.notFound`).
    private static func matchPathParam(route: HTTPRoute, requestPath: String) -> HandlerKind? {
        let dbg = ProcessInfo.processInfo.environment["MOX_DEBUG_ROUTER"] != nil
        if dbg { print("[router.matchPathParam] kind=\(route.kind)") }
        switch route.kind {
        case .loadModel(let id) where id == "__id__":
            // Template: /v1/models/__id__/load
            let prefix = "/v1/models/"
            let suffix = "/load"
            guard requestPath.hasPrefix(prefix), requestPath.hasSuffix(suffix) else { return nil }
            let modelId = String(requestPath.dropFirst(prefix.count).dropLast(suffix.count))
            guard !modelId.isEmpty, !modelId.contains("/") else { return nil }
            return .loadModel(id: modelId)
        case .unloadModel(let id) where id == "__id__":
            let prefix = "/v1/models/"
            let suffix = "/unload"
            guard requestPath.hasPrefix(prefix), requestPath.hasSuffix(suffix) else { return nil }
            let modelId = String(requestPath.dropFirst(prefix.count).dropLast(suffix.count))
            guard !modelId.isEmpty, !modelId.contains("/") else { return nil }
            return .unloadModel(id: modelId)
        default:
            // Exact-match routes — fast path.
            if route.path == requestPath { return route.kind }
            return nil
        }
    }
}

// MARK: - JSON response

/// v0.8 — single JSON response writer that handles both happy-path
/// `Encodable` payloads and structured errors.
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
