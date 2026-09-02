import Foundation

/// `echo`, `logprobs`, `best_of`, `suffix` are decoded for round-trip
/// stability but otherwise ignored by the resolver.
public struct CompletionRequest: Codable, Sendable {
    public let model: String
    public let prompt: String
    public let maxTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let stream: Bool?
    public let streamOptions: ChatStreamOptions?
    public let echo: Bool?
    public let logprobs: Int?
    public let bestOf: Int?
    public let suffix: String?

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream, echo, logprobs, suffix
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case streamOptions = "stream_options"
        case bestOf = "best_of"
    }

    public init(
        model: String,
        prompt: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stream: Bool? = nil,
        streamOptions: ChatStreamOptions? = nil,
        echo: Bool? = nil,
        logprobs: Int? = nil,
        bestOf: Int? = nil,
        suffix: String? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stream = stream
        self.streamOptions = streamOptions
        self.echo = echo
        self.logprobs = logprobs
        self.bestOf = bestOf
        self.suffix = suffix
    }
}

/// OpenAI legacy completions non-stream response. `object` is fixed to
/// `"text_completion"` per the wire contract.
public struct CompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [Choice]
    public let usage: ChatCompletionResponse.Usage

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }

    public init(
        id: String,
        object: String = "text_completion",
        created: Int64,
        model: String,
        choices: [Choice],
        usage: ChatCompletionResponse.Usage
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public struct Choice: Codable, Sendable {
        public let index: Int
        public let text: String
        public let finishReason: String

        enum CodingKeys: String, CodingKey {
            case index, text
            case finishReason = "finish_reason"
        }

        public init(index: Int, text: String, finishReason: String) {
            self.index = index
            self.text = text
            self.finishReason = finishReason
        }
    }
}

/// OpenAI legacy completions streaming chunk. `object` is fixed to
/// `"text_completion"` and `text_completion` per the wire contract.
public struct CompletionChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [Choice]
    public let usage: ChatCompletionChunk.Usage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }

    public struct Choice: Codable, Sendable {
        public let index: Int
        public let text: String
        public let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, text
            case finishReason = "finish_reason"
        }

        public init(index: Int, text: String, finishReason: String?) {
            self.index = index
            self.text = text
            self.finishReason = finishReason
        }
    }

    public init(
        id: String,
        object: String = "text_completion",
        created: Int64,
        model: String,
        choices: [Choice],
        usage: ChatCompletionChunk.Usage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}


public enum ModelSource: String, Codable, Sendable, CaseIterable {
    case huggingface = "huggingface"
    case modelscope = "modelscope"
    case mlxCommunity = "mlx-community"
    /// Sentinel for model directories that pre-date the manifest format. They
    /// have no trustworthy source attribution and should not be confused with
    /// a real provider.
    case unknown = "unknown"
}

public struct ModelInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let source: ModelSource
    public let path: String
    public let size: Int64
    public var lastUsed: Date?
    
    public init(id: String, name: String, source: ModelSource, path: String, size: Int64, lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.path = path
        self.size = size
        self.lastUsed = lastUsed
    }
    
    public var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: size)
    }
}

/// On-disk manifest written to each model directory under `mox.json` after a
/// v0.8 compatibility classification for an installed model. The probe
/// inspects config.json + tokenizer + chat template to determine which
/// upstream architectures mox can run unchanged. Modelled after MTPLX's
/// verified / architecture-compatible / AR-only / incompatible ladder but
/// flattened — mox doesn't ship a curated "verified" list (MIT, no
/// vendor catalog).
public enum CompatibilityTier: String, Codable, Sendable, Equatable {
    /// mlx-swift-lm ships a first-class `ModelType` for this architecture.
    case mlxBuiltin
    /// mlx-swift-lm has a path but with reduced confidence (community
    /// port, archived model). Loads but labelled.
    case communityUnverified
    /// mox can only run this as a target-only AR generation; no
    /// speculative-decoding path, no prefix cache, no tool parser.
    case arOnly
    /// The architecture is recognised by config.json but mlx-swift-lm
    /// has no matching `ModelType` — refuse to load.
    case incompatible
    /// The probe could not decide. Surface as "unknown", never silently
    /// downgrade.
    case unknown
}



public struct ModelCompatibility: Codable, Sendable, Equatable {
    public let tier: CompatibilityTier
    /// Human-readable reason — model_type observed, missing fields, etc.
    /// Persisted so `mox list --check` can show it without re-probing.
    public let reason: String?
    public let modelType: String?
    public let probedAt: Date

    public init(
        tier: CompatibilityTier,
        reason: String? = nil,
        modelType: String? = nil,
        probedAt: Date = Date()
    ) {
        self.tier = tier
        self.reason = reason
        self.modelType = modelType
        self.probedAt = probedAt
    }
}

/// On-disk manifest written to each model directory under `mox.json` after a
/// successful pull. Records the canonical model id, the source, the originally
/// requested id, and the install timestamp. The manifest is the source of
/// truth for `source` so that callers never have to reverse-engineer it from
/// the directory name.
public struct ModelManifest: Codable, Sendable {
    public var id: String
    public var source: ModelSource
    public var originalId: String
    public var installedAt: Date
    /// v0.5+ — what was the upstream's weight format? Drives `mox list`
    /// and the future `mox convert` routing.
    public var sourceFormat: String?
    /// v0.5+ — populated when Mox did the quantization itself (e.g.
    /// `requantize`); nil for upstream-quantized or bf16 models.
    public var quantization: MoxQuantizationInfo?
    /// v0.8+ — compatibility tier observed when the manifest was last
    /// written. Re-probed at load time; mismatch is reported, not
    /// silently overridden.
    public var compatibility: ModelCompatibility?
    /// v0.8.3+ — upstream revision pin last observed by `mox update`.
    /// nil for legacy installs that pre-date update-tracking.
    public var revision: String?

    public init(
        id: String,
        source: ModelSource,
        originalId: String,
        installedAt: Date = Date(),
        sourceFormat: String? = nil,
        quantization: MoxQuantizationInfo? = nil,
        compatibility: ModelCompatibility? = nil,
        revision: String? = nil
    ) {
        self.id = id
        self.source = source
        self.originalId = originalId
        self.installedAt = installedAt
        self.sourceFormat = sourceFormat
        self.quantization = quantization
        self.compatibility = compatibility
        self.revision = revision
    }
}

public struct MoxQuantizationInfo: Codable, Sendable {
    public let bits: Int
    public let groupSize: Int
    public let mode: String
    public let appliedAt: Date

    public init(bits: Int, groupSize: Int, mode: String, appliedAt: Date = Date()) {
        self.bits = bits
        self.groupSize = groupSize
        self.mode = mode
        self.appliedAt = appliedAt
    }
}

public struct AppConfig: Codable, Sendable {
    public var version: Int = 1
    public var defaultSource: ModelSource = .huggingface
    public var mirrors: Mirrors = Mirrors()
    public var server: ServerConfig = ServerConfig()
    public var defaults: ModelDefaults = ModelDefaults()
    public var memory: MemoryConfig = MemoryConfig()
    
    public init() {}
    
    public struct Mirrors: Codable, Sendable {
        public var huggingface: String = ""
        public var modelscope: String = ""
        
        public init() {}
    }

    public struct ServerConfig: Codable, Sendable {
        public var host: String = "127.0.0.1"
        public var port: Int = 11555

        public init() {}
    }
    
    public struct ModelDefaults: Codable, Sendable {
        public var maxTokens: Int = 2048
        public var temperature: Double = 0.7
        public var topP: Double = 0.9
        
        public init() {}
    }
    
    public struct MemoryConfig: Codable, Sendable {
        public var reservePercent: Double = 0.1
        /// v0.8.5+ — model ids that `ModelRegistry` must keep resident
        /// across evictions. Surfaces in `mox.json` so a config can
        /// pin "the chat model" while letting the embedder model be
        /// evicted on memory pressure. Empty by default.
        public var pinnedModels: [String] = []

        public init() {}
    }
}

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String
    
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let stream: Bool?
    public let streamOptions: ChatStreamOptions?
    /// v0.8+ — OpenAI tool definitions. Decoded as opaque `AnyCodable`
    /// so we don't need to version every client schema; the resolver
    /// validates `name` is non-empty.
    public let tools: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case streamOptions = "stream_options"
    }

    public init(
        model: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stream: Bool? = nil,
        streamOptions: ChatStreamOptions? = nil,
        tools: [AnyCodable]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stream = stream
        self.streamOptions = streamOptions
        self.tools = tools
    }
}

public struct ChatStreamOptions: Codable, Sendable {
    public let includeUsage: Bool?
    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
    public init(includeUsage: Bool? = nil) {
        self.includeUsage = includeUsage
    }
}

/// OpenAI-shape `tool_calls` array element on an assistant message.
public struct OpenAIToolCall: Codable, Sendable, Equatable {
    public let index: Int?
    public let id: String?
    public let type: String?
    public let function: Function

    public struct Function: Codable, Sendable, Equatable {
        public let name: String?
        public let arguments: String?

        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(index: Int? = nil, id: String? = nil, type: String? = nil, function: Function) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatCompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [Choice]
    public let usage: Usage
    
    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }
    
    public init(id: String, object: String = "chat.completion", created: Int64, model: String, choices: [Choice], usage: Usage) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
    
    public struct Choice: Codable, Sendable {
        public let index: Int
        public let message: AssistantMessage
        public let finishReason: String
        
        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
        
        public init(index: Int, message: AssistantMessage, finishReason: String) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }
    }
    
    public struct AssistantMessage: Codable, Sendable {
        public let role: String
        public let content: String
        /// v0.8+ — populated when the model emitted tool calls instead of
        /// (or in addition to) free-form content.
        public let toolCalls: [OpenAIToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }

        public init(
            role: String = "assistant",
            content: String,
            toolCalls: [OpenAIToolCall]? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
        }
    }
    
    public struct Usage: Codable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
        
        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }
}

/// OpenAI-compatible streaming chunk. One document per line on the wire; the
/// SSE endpoint emits the same shape so the CLI subcommand and the GUI
/// client agree on format. `usage` is only populated on the trailing chunk
/// when the client set `stream_options.include_usage`.
public struct ChatCompletionChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [Choice]
    public let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }

    public struct Choice: Codable, Sendable {
        public let index: Int
        public let delta: Delta
        public let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }

        public init(index: Int, delta: Delta, finishReason: String?) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }
    }

    public struct Delta: Codable, Sendable {
        public let role: String?
        public let content: String

        public init(role: String? = nil, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct Usage: Codable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }

        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }

    public init(
        id: String,
        object: String,
        created: Int64,
        model: String,
        choices: [Choice],
        usage: Usage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}
/// Lives in `MoxShared` (rather than `ModelError` in `MoxCore`) so the resolver
/// protocol can throw it without a back-dependency.
public enum MirrorError: Error, LocalizedError {
    case invalidMirror(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMirror(let mirror):
            return "Mirror host not on allowlist: '\(mirror)'"
        }
    }
}

/// Hard-coded host allowlist for HuggingFace mirrors. Only well-known,
/// first-party mirrors are accepted; arbitrary hosts must NOT be silently
/// trusted.
public enum HuggingFaceMirrorPolicy {
    public static let allowedHosts: Set<String> = ["huggingface.co", "hf-mirror.com"]
}

/// Hard-coded host allowlist for ModelScope mirrors.
public enum ModelScopeMirrorPolicy {
    public static let allowedHosts: Set<String> = ["modelscope.cn"]
}
public protocol ModelSourceResolver: Sendable {
    var name: String { get }
    func resolveModelId(_ id: String) -> String
    func downloadURL(for modelId: String) -> URL?
    /// Validate that any configured mirror host is on this source's allowlist.
    /// Throws `MirrorError.invalidMirror` if a mirror is set to a non-allowed host.
    func validateMirror() throws
}


public struct HuggingFaceSource: ModelSourceResolver, Sendable {
    public let name = "huggingface"
    public let mirror: String?

    public init(mirror: String? = nil) throws {
        self.mirror = mirror
        try validateMirror()
    }

    public func resolveModelId(_ id: String) -> String {
        if id.contains("/") {
            return id
        }
        return "mlx-community/\(id)"
    }

    public func downloadURL(for modelId: String) -> URL? {
        let base = mirror ?? "https://huggingface.co"
        return URL(string: "\(base)/\(modelId)")
    }

    public func validateMirror() throws {
        guard let mirror else { return }
        guard let host = URL(string: mirror)?.host?.lowercased() else {
            throw MirrorError.invalidMirror(mirror)
        }
        if !HuggingFaceMirrorPolicy.allowedHosts.contains(host) {
            throw MirrorError.invalidMirror(mirror)
        }
    }
}

public struct ModelScopeSource: ModelSourceResolver, Sendable {
    public let name = "modelscope"
    public let mirror: String?

    public init(mirror: String? = nil) throws {
        self.mirror = mirror
        try validateMirror()
    }

    public func resolveModelId(_ id: String) -> String {
        return id
    }

    public func downloadURL(for modelId: String) -> URL? {
        let base = mirror ?? "https://modelscope.cn"
        return URL(string: "\(base)/\(modelId)")
    }

    public func validateMirror() throws {
        guard let mirror else { return }
        guard let host = URL(string: mirror)?.host?.lowercased() else {
            throw MirrorError.invalidMirror(mirror)
        }
        if !ModelScopeMirrorPolicy.allowedHosts.contains(host) {
            throw MirrorError.invalidMirror(mirror)
        }
    }
}

public actor SourceRegistry {
    public static let shared = SourceRegistry()

    private var sources: [String: ModelSourceResolver] = [:]

    public init() {
        // Default sources are constructed with `nil` mirror, which cannot fail
        // validation; a failed construction here means a programmer error, not
        // a runtime condition. Actor initializers run synchronously, so we can
        // populate state directly.

        sources["huggingface"] = try! HuggingFaceSource()
        sources["modelscope"] = try! ModelScopeSource()
    }

    public func registerSource(_ source: ModelSourceResolver) {
        sources[source.name] = source
    }

    public func resolver(for name: String) -> ModelSourceResolver? {
        sources[name]
    }

    public func resolve(modelId: String, sourceType: ModelSource) -> String {
        let resolver = sources[sourceType.rawValue] ?? sources["huggingface"]!
        return resolver.resolveModelId(modelId)
    }
}

public enum DownloadError: Error, LocalizedError {
    case invalidModelId
    case networkError(String)
    case insufficientSpace(required: Int64, available: Int64)
    case downloadFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidModelId:
            return "Invalid model ID format"
        case .networkError(let message):
            return "Network error: \(message)"
        case .insufficientSpace(let required, let available):
            return "Insufficient disk space. Required: \(required) bytes, Available: \(available) bytes"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        }
    }
}

public struct DownloadProgress: Sendable {
    public let modelId: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let progress: Double
    
    public init(modelId: String, bytesDownloaded: Int64, totalBytes: Int64) {
        self.modelId = modelId
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.progress = totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
    }
}

public protocol DownloadProgressObserver: AnyObject, Sendable {
    func downloadProgressUpdated(_ progress: DownloadProgress)
}

// MARK: - Anthropic Messages API

/// Anthropic Messages API request shape. Mirrors the official Anthropic
/// SDK's `MessageCreateParams` (text-only subset). v0.4.1 does not support
/// `tools` — those requests return 400 from the handler. `system` accepts
/// either a plain string or a single text content block (the latter is
/// normalised to a string before being forwarded to the model).
public struct AnthropicMessagesRequest: Codable, Sendable {
    public let model: String
    public let messages: [AnthropicMessage]
    public let system: AnthropicSystemContent?
    public let maxTokens: Int
    public let temperature: Double?
    public let topP: Double?
    public let stream: Bool?
    /// Reserved — v0.4.1 returns 400 if any tool is supplied.
    public let tools: [AnthropicTool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, system, stream, tools
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
    }

    public init(
        model: String,
        messages: [AnthropicMessage],
        system: AnthropicSystemContent? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        stream: Bool? = nil,
        tools: [AnthropicTool]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.system = system
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stream = stream
        self.tools = tools
    }
}

public struct AnthropicMessage: Codable, Sendable {
    public let role: String
    public let content: AnthropicMessageContent
    public init(role: String, content: AnthropicMessageContent) {
        self.role = role
        self.content = content
    }
}

/// Anthropic accepts either a plain text string or an array of content
/// blocks. Mox only handles text blocks; images/tool_use/tool_result blocks
/// are decoded but treated as opaque text (their JSON is preserved so we
/// can detect unsupported requests and 400 them).
public enum AnthropicMessageContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s); return
        }
        let blocks = try container.decode([AnthropicContentBlock].self)
        self = .blocks(blocks)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }

    /// Flatten to plain text for forwarding to the model.
    public var flattenedText: String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                if case .text(let s) = block { return s }
                return nil
            }.joined(separator: "\n")
        }
    }
}

public enum AnthropicContentBlock: Codable, Sendable {
    case text(String)
    case other(type: String, raw: [String: AnyCodable])

    private enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: Decoder) throws {
        // Decode the entire block as free-form AnyCodable so we preserve
        // unknown block shapes (image, tool_use, …) verbatim and the
        // handler can decide whether to 400.
        let any = try AnyCodable(from: decoder)
        guard case .object(let raw) = any else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "AnthropicContentBlock expected object"
            )
        }
        let type = raw["type"]?.stringValue ?? ""
        if type == "text", let text = raw["text"]?.stringValue {
            self = .text(text)
        } else {
            self = .other(type: type, raw: raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        // Emit a single value (object) so AnyCodable's `encode(to:)` writes
        // the full dictionary verbatim — including any "other" shape.
        let obj: AnyCodable
        switch self {
        case .text(let s):
            obj = .object(["type": .string("text"), "text": .string(s)])
        case .other(_, let raw):
            obj = .object(raw)
        }
        try obj.encode(to: encoder)
    }
}

extension AnthropicContentBlock {
    /// Convenience for downstream callers that only care about text.
    public var flattenedText: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

public enum AnthropicSystemContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s); return
        }
        let blocks = try container.decode([AnthropicContentBlock].self)
        self = .blocks(blocks)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }

    public var flattenedText: String? {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            let texts = blocks.compactMap { b -> String? in
                if case .text(let s) = b { return s }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
    }
}

/// Reserved for `tools[]` — v0.4.1 always rejects. We decode the shape
/// only so a malformed tool definition produces a structured 400 instead
/// of a parse error.
public struct AnthropicTool: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: AnyCodable
    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
    public init(name: String, description: String?, inputSchema: AnyCodable) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Anthropic non-streaming response. Wire shape:
/// ```json
/// {
///   "id": "msg_...",
///   "type": "message",
///   "role": "assistant",
///   "content": [{"type":"text","text":"..."}],
///   "model": "...",
///   "stop_reason": "end_turn",
///   "usage": {"input_tokens":N,"output_tokens":M}
/// }
/// ```
public struct AnthropicMessagesResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let content: [AnthropicContentBlock]
    public let model: String
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: AnthropicUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    public init(
        id: String,
        type: String = "message",
        role: String = "assistant",
        content: [AnthropicContentBlock],
        model: String,
        stopReason: String? = nil,
        stopSequence: String? = nil,
        usage: AnthropicUsage
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }
}

public struct AnthropicUsage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AnthropicErrorResponse: Codable, Sendable {
    public struct ErrorBody: Codable, Sendable {
        public let type: String
        public let message: String
        public init(type: String, message: String) {
            self.type = type
            self.message = message
        }
    }
    public let type: String = "error"
    public let error: ErrorBody
    public init(error: ErrorBody) { self.error = error }
}

/// OpenAI-style error envelope: `{"error":{"message","type","code"}}`.
/// v0.8 — single envelope for the OpenAI endpoint family. Anthropic
/// uses `AnthropicErrorResponse` instead. Both share the same `type`
/// and `message` field names but the outer wrapping differs.
public struct OpenAIErrorBody: Codable, Sendable, Equatable {
    public let message: String
    public let type: String
    public let code: String?

    public init(message: String, type: String, code: String? = nil) {
        self.message = message
        self.type = type
        self.code = code
    }
}

public struct OpenAIErrorPayload: Codable, Sendable, Equatable {
    public let error: OpenAIErrorBody

    public init(error: OpenAIErrorBody) { self.error = error }
}


/// Type-erased JSON value for fields we want to decode but don't care
/// about the exact shape of (AnthropicTool.inputSchema, content blocks
/// of unknown type).
public enum AnyCodable: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyCodable].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnyCodable].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "AnyCodable: unsupported value"
        )
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension AnyCodable {
    /// Convenience for places that know they're decoding a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    /// Convenience for places that know they're decoding a dictionary.
    public var objectValue: [String: AnyCodable]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - BinaryLocator
//
// Single source of truth for where to look for `mox` / `mox-server` on disk.
// The candidate order matches DESIGN §1: Apple-Silicon Homebrew first
// (`/opt/homebrew/bin`), Intel Homebrew + manual installs second
// (`/usr/local/bin`), the system prefix third (`/usr/bin`), then the PATH
// fallback. Returning the first executable file keeps `mox-server install`
// honest about what it actually registered with launchd — the previous
// `uname -m`-based guess returned paths that did not exist on the host.
public enum BinaryLocator {
    /// Conventional install locations in priority order. The first entry that
    /// resolves to an existing executable wins.
    public static let defaultCandidates: [String] = [
        "/opt/homebrew/bin",          // Apple-Silicon Homebrew (default prefix)
        "/usr/local/bin",             // Intel Homebrew + manual installs
        "/usr/bin",                   // System-managed copies (rare)
    ]

    /// Resolves the absolute path to an executable named `name`, searching
    /// `defaultCandidates` then `$PATH`. Returns `nil` when no executable
    /// file is found — callers must surface that as an install error rather
    /// than silently pick a non-existent path.
    public static func locate(named name: String) -> String? {
        let fm = FileManager.default
        for dir in defaultCandidates {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // PATH fallback: explicit iteration avoids shell quoting surprises
        // and login-shell PATH differences between GUI and CLI launches.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
