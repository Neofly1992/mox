import Foundation
import MoxShared

/// Uniform gateway between the SwiftUI front-end and either of Mox's two
/// backends (a long-lived `mox-server` daemon or a one-shot `mox` child
/// process). The two implementations must produce equivalent observable
/// behaviour so the GUI can swap modes without code changes elsewhere.
///
/// Design notes:
///
/// - We deliberately depend only on `MoxShared` so the GUI target never
///   drags in `MoxCore` (and therefore MLX / Hub / Tokenizers). The whole
///   point of `ProcessAPIClient` is that MoxCore lives in another process.
/// - `chat(...)` returns an `AsyncStream<String>`. Each yielded element is a
///   delta of assistant content; callers append it to the current assistant
///   message. We do not yield OpenAI chunk envelopes here because the GUI
///   does not need them — it only cares about the text.
/// - `cancelChat()` is best-effort. HTTP clients cancel the in-flight
///   `URLSessionTask`; the process client terminates its child.
public protocol MoxAPIClient: Sendable {
    /// Streams assistant content for the given messages.
    /// - Parameters:
    ///   - modelId: model identifier (e.g. `mlx-community/Qwen2.5-0.5B-Instruct`).
    ///   - messages: full conversation history in OpenAI order.
    ///   - stream: when `true`, the client requests incremental output; when
    ///     `false`, it returns the assembled response as a single element.
    /// - Returns: an `AsyncStream<String>` of text deltas. The stream finishes
    ///   on normal completion or on error after yielding nothing further.
    func chat(modelId: String, messages: [ChatMessage], stream: Bool) async throws -> AsyncStream<String>

    /// Lists models available on the backend. The daemon returns whatever
    /// `GET /v1/models` returns; the process client shells out to
    /// `mox list` and parses the table.
    func listModels() async throws -> [ModelInfo]

    /// Cancels the in-flight chat, if any. Safe to call when nothing is
    /// running — implementations should treat that as a no-op.
    func cancelChat() async throws
}

// MARK: - Errors

public enum MoxAPIClientError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case http(status: Int, body: String)
    case decoding(String)
    case processSpawn(String)
    case processExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .decoding(let s): return "Decoding failed: \(s)"
        case .processSpawn(let s): return "Process spawn failed: \(s)"
        case .processExit(let code, let stderr):
            if stderr.isEmpty { return "Process exited with code \(code)" }
            return "Process exited with code \(code): \(stderr)"
        }
    }
}

// MARK: - HTTP client

/// Talks to a running `mox-server` daemon over HTTP. The v0.3 daemon only
/// speaks the non-streaming JSON variant of `/v1/chat/completions`, so when
/// the caller asks for `stream: true` we still get the full response back in
/// one shot and yield it as a single chunk. SSE lands in a later milestone;
/// the protocol surface here stays the same so the GUI doesn't need to
/// change when it does.
public final class HTTPAPIClient: MoxAPIClient, @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func chat(modelId: String, messages: [ChatMessage], stream: Bool) async throws -> AsyncStream<String> {
        let request = ChatCompletionRequest(
            model: modelId,
            messages: messages,
            stream: stream
        )
        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MoxAPIClientError.http(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MoxAPIClientError.http(status: http.statusCode, body: body)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw MoxAPIClientError.decoding(String(describing: error))
        }

        // Yield the assembled content once; cancellation is handled by the
        // caller dropping the iterator.
        return AsyncStream { continuation in
            let text = decoded.choices.first?.message.content ?? ""
            continuation.yield(text)
            continuation.finish()
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("/v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MoxAPIClientError.http(status: status, body: body)
        }

        // /v1/models returns OpenAI-shape ModelItems, not MoxShared.ModelInfo
        // — translate them so callers can use one type.
        struct ModelItem: Decodable {
            let id: String
            let name: String
            let source: String
            let size: Int64
        }
        struct Envelope: Decodable { let data: [ModelItem] }

        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return env.data.map { item in
                ModelInfo(
                    id: item.id,
                    name: item.name,
                    source: ModelSource(rawValue: item.source) ?? .unknown,
                    path: "",
                    size: item.size
                )
            }
        } catch {
            throw MoxAPIClientError.decoding(String(describing: error))
        }
    }

    public func cancelChat() async throws {
        // URLSession.data(for:) doesn't expose a cancellable handle directly,
        // so cancellation propagates via Task cancellation when the caller
        // awaits inside a Task — which is the contract here.
    }
}

// MARK: - Process client

/// Spawns `mox` as a child process and parses its stdout. Used when no daemon
/// is running. The CLI's `mox ask --stream` emits one OpenAI chunk JSON per
/// line; we decode each line and yield its delta. Non-streaming falls back
/// to the CLI's single-document mode (also `mox ask`).
public final class ProcessAPIClient: MoxAPIClient, @unchecked Sendable {
    public let binaryPath: String

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    public func chat(modelId: String, messages: [ChatMessage], stream: Bool) async throws -> AsyncStream<String> {
        let args = [
            "ask",
            "--model", modelId,
            "--messages", encodeMessages(messages)
        ] + (stream ? ["--stream"] : [])

        let proc = try Self.spawn(binaryPath: binaryPath, args: args)
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let drain = Task.detached(priority: .userInitiated) {
                guard let pipe = proc.standardOutput as? Pipe else {
                    continuation.finish()
                    return
                }
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: 0..<nl)
                        buffer.removeSubrange(0...nl)
                        if line.isEmpty { continue }
                        if stream {
                            if let text = Self.extractContent(from: line),
                               !text.isEmpty {
                                continuation.yield(text)
                            }
                        } else {
                            // Non-streaming: the CLI emits exactly one
                            // JSON ChatCompletionResponse. Yield its
                            // content once.
                            if let text = Self.extractFinalContent(from: line) {
                                continuation.yield(text)
                            }
                        }
                    }
                }
                if !buffer.isEmpty {
                    let text = stream
                        ? Self.extractContent(from: buffer)
                        : Self.extractFinalContent(from: buffer)
                    if let text, !text.isEmpty {
                        continuation.yield(text)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drain.cancel()
                if proc.isRunning { proc.terminate() }
            }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        let proc = try Self.spawn(binaryPath: binaryPath, args: ["list"])
        proc.waitUntilExit()
        let outPipe = proc.standardOutput as? Pipe
        let errPipe = proc.standardError as? Pipe
        let outData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let outString = String(data: outData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data(), encoding: .utf8) ?? ""
            throw MoxAPIClientError.processExit(code: proc.terminationStatus, stderr: err)
        }
        return Self.parseListTable(outString)
    }

    public func cancelChat() async throws {
        // Process-based cancellation is handled via the AsyncStream
        // termination handler in chat(...): when the consumer drops its
        // iterator, the child process is terminated. This method is a
        // no-op kept on the protocol for symmetry with HTTPAPIClient.
    }

    // MARK: - Static helpers

    private static func spawn(binaryPath: String, args: [String]) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw MoxAPIClientError.processSpawn(String(describing: error))
        }
        return proc
    }

    private func encodeMessages(_ messages: [ChatMessage]) -> String {
        // Compact JSON keeps the argv manageable; the CLI's JSONDecoder handles
        // both compact and pretty-printed inputs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        if let data = try? encoder.encode(messages),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }

    /// Parses a single streaming chunk JSON line and returns the delta's
    /// content. Mirrors the `StreamChunk` shape used by `mox ask --stream`.
    private static func extractContent(from data: Data) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                }
                let delta: Delta
            }
            let choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        return chunk.choices.first?.delta.content
    }

    /// Parses the non-streaming `ChatCompletionResponse` document.
    private static func extractFinalContent(from data: Data) -> String? {
        if let resp = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
            return resp.choices.first?.message.content
        }
        return nil
    }

    /// Parses the human-readable table produced by `mox list` into
    /// `ModelInfo` values. The CLI prints columns NAME / SOURCE / SIZE; we
    /// split on the last two whitespace-delimited tokens for size + source.
    private static func parseListTable(_ text: String) -> [ModelInfo] {
        var infos: [ModelInfo] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Installed models") { continue }
            if line.hasPrefix("NAME") { continue }
            if line.allSatisfy({ $0 == "-" }) { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { continue }
            let sourceStr = parts.dropLast().last ?? ""
            let name = parts.dropLast(2).joined(separator: " ")
            infos.append(ModelInfo(
                id: name,
                name: name,
                source: ModelSource(rawValue: sourceStr) ?? .unknown,
                path: "",
                size: 0
            ))
        }
        return infos
    }
}

// MARK: - Client selection

/// Convenience factory used by the GUI's mode-detection logic. The GUI
/// decides whether to talk to a daemon or fall back to a child process; this
/// factory keeps that decision in one place rather than scattering it across
/// views.
public enum MoxAPIClientFactory {
    /// Constructs a process-backed client using the conventional binary
    /// locations. The GUI uses this when no daemon is reachable.
    public static func defaultProcessClient() -> ProcessAPIClient {
        let candidates = [
            "/usr/local/bin/mox",
            "/opt/homebrew/bin/mox"
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return ProcessAPIClient(binaryPath: path)
        }
        // Fall back to the first candidate even if it doesn't exist —
        // ProcessAPIClient will surface a clean error at first use.
        return ProcessAPIClient(binaryPath: candidates[0])
    }
}
