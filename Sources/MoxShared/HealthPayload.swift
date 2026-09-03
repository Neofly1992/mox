/// Default sampler values advertised via `/health`. Mirrors the fields
/// `RequestPolicy.ServerDefaults` consumes; kept separate from the wire
/// contract so future renames in either layer stay isolated.
public struct SamplerDefaults: Sendable, Codable, Equatable {
    public let temperature: Double
    public let topP: Double
    public let maxTokens: Int
    public init(temperature: Double = 0.7, topP: Double = 0.9, maxTokens: Int = 2048) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}



/// Wire shape for `GET /health`. v0.7+ exposes a richer body than the bare
/// `{"status":"ok"}` of v0.6 so coding-agent clients can introspect the
/// runtime without round-tripping `/v1/models`. Fields are versioned by
/// `moxVersion` so older clients can ignore new keys safely.
public let moxHealthPayloadVersion = "0.8.6"

public struct HealthPayload: Codable, Sendable, Equatable {
    public let status: String
    public let moxVersion: String
    public let serverVersion: String
    public let models: [ModelCapability]
    public let capabilities: Capabilities
    public let samplerDefaults: SamplerDefaults
    public let runtime: Runtime

    enum CodingKeys: String, CodingKey {
        case status
        case moxVersion = "mox_version"
        case serverVersion = "server_version"
        case models
        case capabilities
        case samplerDefaults = "sampler_defaults"
        case runtime
    }

    public init(
        status: String,
        moxVersion: String,
        serverVersion: String,
        models: [ModelCapability],
        capabilities: Capabilities,
        samplerDefaults: SamplerDefaults,
        runtime: Runtime
    ) {
        self.status = status
        self.moxVersion = moxVersion
        self.serverVersion = serverVersion
        self.models = models
        self.capabilities = capabilities
        self.samplerDefaults = samplerDefaults
        self.runtime = runtime
    }

    public struct ModelCapability: Codable, Sendable, Equatable {
        public let id: String
        public let family: String?
        public let loaded: Bool
        public let supportsToolCalls: Bool
        public let contextWindow: Int?
        public let warmupTokens: Int?
        /// v0.8+ — compatibility tier from `CompatibilityProbe`.
        public let compatibility: String?
        public let compatibilityReason: String?

        enum CodingKeys: String, CodingKey {
            case id
            case family
            case loaded
            case supportsToolCalls = "supports_tool_calls"
            case contextWindow = "context_window"
            case warmupTokens = "warmup_tokens"
            case compatibility
            case compatibilityReason = "compatibility_reason"
        }

        public init(
            id: String,
            family: String? = nil,
            loaded: Bool,
            supportsToolCalls: Bool,
            contextWindow: Int? = nil,
            warmupTokens: Int? = nil,
            compatibility: String? = nil,
            compatibilityReason: String? = nil
        ) {
            self.id = id
            self.family = family
            self.loaded = loaded
            self.supportsToolCalls = supportsToolCalls
            self.contextWindow = contextWindow
            self.warmupTokens = warmupTokens
            self.compatibility = compatibility
            self.compatibilityReason = compatibilityReason
        }
    }

    public struct Capabilities: Codable, Sendable, Equatable {
        public let openaiChatCompletions: Bool
        public let openaiCompletions: Bool
        public let openaiStream: Bool
        public let openaiUsage: Bool
        public let anthropicMessages: Bool
        public let anthropicStream: Bool
        public let toolCalls: Bool
        public let embeddings: Bool

        enum CodingKeys: String, CodingKey {
            case openaiChatCompletions = "openai_chat_completions"
            case openaiCompletions = "openai_completions"
            case openaiStream = "openai_stream"
            case openaiUsage = "openai_usage"
            case anthropicMessages = "anthropic_messages"
            case anthropicStream = "anthropic_stream"
            case toolCalls = "tool_calls"
            case embeddings
        }

        public init(
            openaiChatCompletions: Bool,
            openaiCompletions: Bool,
            openaiStream: Bool,
            openaiUsage: Bool,
            anthropicMessages: Bool,
            anthropicStream: Bool,
            toolCalls: Bool,
            embeddings: Bool
        ) {
            self.openaiChatCompletions = openaiChatCompletions
            self.openaiCompletions = openaiCompletions
            self.openaiStream = openaiStream
            self.openaiUsage = openaiUsage
            self.anthropicMessages = anthropicMessages
            self.anthropicStream = anthropicStream
            self.toolCalls = toolCalls
            self.embeddings = embeddings
        }

        public static let v07 = Capabilities(
            openaiChatCompletions: true,
            openaiCompletions: true,
            openaiStream: true,
            openaiUsage: true,
            anthropicMessages: true,
            anthropicStream: true,
            toolCalls: true,
            embeddings: false
        )
    }

    public struct Runtime: Codable, Sendable, Equatable {
        public let host: String
        public let port: Int
        public let maxBodyBytes: Int
        /// v0.8.6+ — cache budget (bytes) that `ModelRegistry` enforces
        /// for resident model weights. nil when the runner hasn't
        /// initialised its registry yet (cold start, before any
        /// model loaded).
        public let cacheBudgetBytes: Int64?
        /// v0.8.6+ — cache headroom remaining (bytes) within
        /// `cacheBudgetBytes`. Nil alongside `cacheBudgetBytes`.
        public let cacheUsedBytes: Int64?
        /// v0.8.6+ — number of models currently resident in the
        /// runner (across all sources — huggingface, mlx-community,
        /// modelscope, etc).
        public let loadedModelCount: Int

        enum CodingKeys: String, CodingKey {
            case host
            case port
            case maxBodyBytes = "max_body_bytes"
            case cacheBudgetBytes = "cache_budget_bytes"
            case cacheUsedBytes = "cache_used_bytes"
            case loadedModelCount = "loaded_model_count"
        }

        public init(
            host: String,
            port: Int,
            maxBodyBytes: Int,
            cacheBudgetBytes: Int64? = nil,
            cacheUsedBytes: Int64? = nil,
            loadedModelCount: Int = 0
        ) {
            self.host = host
            self.port = port
            self.maxBodyBytes = maxBodyBytes
            self.cacheBudgetBytes = cacheBudgetBytes
            self.cacheUsedBytes = cacheUsedBytes
            self.loadedModelCount = loadedModelCount
        }
    }
}