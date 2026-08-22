import Foundation

/// Shared resolution for sampler fields, max-tokens, and stream defaults across
/// every public endpoint (`/v1/chat/completions`, `/v1/messages`,
/// `/v1/completions`). All handlers must funnel raw requests through
/// `RequestPolicy.resolve` so server-side defaults and validation are applied
/// in one place — divergence here is the v0.7+ regression risk the project
/// roadmap calls out.
///
/// Three sources of a field's value, in priority order:
/// - `.client`: caller sent the field verbatim.
/// - `.server`: caller omitted the field; the server falls back to a default
///   from `ServerDefaults`.
/// - `.default`: caller omitted the field and the server has no override;
///   the resolver emits a hard-coded product default.
///
/// The enum exists so observers (logging, telemetry) can distinguish "user
/// asked for 0.3 temperature" from "user didn't ask, server picks 0.7".
public enum SamplerSource: String, Codable, Sendable {
    case client
    case server
    case `default`
}

public enum MoxError: Error, LocalizedError, Equatable, Sendable {
    case invalidModelId(String)
    case emptyMessages
    case invalidTools(reason: String)
    case nonFiniteSampler(field: String, value: Double)
    case maxTokensOutOfRange(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidModelId(let id):
            return "invalid model id: '\(id)'"
        case .emptyMessages:
            return "request must include at least one message"
        case .invalidTools(let reason):
            return reason
        case .nonFiniteSampler(let field, let value):
            return "\(field) must be a finite number (got \(value))"
        case .maxTokensOutOfRange(let n):
            return "max_tokens must be positive (got \(n))"
        }
    }
}

public struct ResolvedTemperature: Sendable, Codable, Equatable {
    public let value: Double
    public let source: SamplerSource
    public init(value: Double, source: SamplerSource) {
        self.value = value
        self.source = source
    }
}

public struct ResolvedTopP: Sendable, Codable, Equatable {
    public let value: Double
    public let source: SamplerSource
    public init(value: Double, source: SamplerSource) {
        self.value = value
        self.source = source
    }
}

public struct ResolvedSampler: Sendable, Codable {
    public let temperature: ResolvedTemperature
    public let topP: ResolvedTopP
    public let maxTokens: Int
    public let stream: Bool
    public init(
        temperature: ResolvedTemperature,
        topP: ResolvedTopP,
        maxTokens: Int,
        stream: Bool
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stream = stream
    }
}

/// Server-side defaults the resolver consults when a client omits a field.
/// Constructed from `AppConfig.ModelDefaults` at handler entry; never mutated
/// inside the resolver. The product-wide hard defaults live in `resolve`
/// itself so the resolver is testable without spinning up a config file.
public struct ServerDefaults: Sendable {
    public let temperature: Double
    public let topP: Double
    public let maxTokens: Int

    public init(temperature: Double, topP: Double, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public static let productFallback = ServerDefaults(
        temperature: 0.7,
        topP: 0.9,
        maxTokens: 2048
    )

    public init(appConfig: AppConfig.ModelDefaults) {
        self.init(
            temperature: appConfig.temperature,
            topP: appConfig.topP,
            maxTokens: appConfig.maxTokens
        )
    }
}

/// Inputs the resolver expects from each endpoint. The handler fills only the
/// fields the endpoint actually carries — `messages` is non-empty for chat,
/// `prompt` is non-empty for completions, `tools` is only set by the wire
/// decoders. Resolving with both `messages` and `prompt` is allowed (legacy
/// clients sometimes do this) but the prompt-style fallback is only emitted
/// when `messages` is empty.
public struct ResolutionInput: Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let prompt: String?
    public let rawTemperature: Double?
    public let rawTopP: Double?
    public let rawMaxTokens: Int?
    public let rawStream: Bool?
    /// Raw tool definitions the client sent. The resolver validates each
    /// entry has a non-empty `name`; deeper schema checks belong to the
    /// parser downstream. `ResolvedRequest.tools` is the parsed form.
    public let rawTools: [AnyCodable]
    public let apiKey: ServerDefaults

    public init(
        model: String,
        messages: [ChatMessage] = [],
        prompt: String? = nil,
        rawTemperature: Double? = nil,
        rawTopP: Double? = nil,
        rawMaxTokens: Int? = nil,
        rawStream: Bool? = nil,
        rawTools: [AnyCodable] = [],
        apiKey: ServerDefaults = .productFallback
    ) {
        self.model = model
        self.messages = messages
        self.prompt = prompt
        self.rawTemperature = rawTemperature
        self.rawTopP = rawTopP
        self.rawMaxTokens = rawMaxTokens
        self.rawStream = rawStream
        self.rawTools = rawTools
        self.apiKey = apiKey
    }
}

public struct ResolvedRequest: Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let sampler: ResolvedSampler
    /// Validated tool definitions. Each entry must have a non-empty
    /// `name`. `tool_choice` is left to the caller.
    public let tools: [AnyCodable]
    /// Optional family hint for downstream parser dispatch. Sourced from
    /// the loaded model's `modelFamily` field; nil if the model hasn't
    /// been loaded yet (cold path).
    public let modelFamilyHint: String?
    public let resolvedAt: Date
}

/// Single funnel for every server endpoint. Each endpoint calls this exactly
/// once after decoding its wire form. The contract:
/// - empty prompts/messages are rejected before sampler resolution,
/// - non-finite samplers reject with `MoxError.nonFiniteSampler`,
/// - `max_tokens` must be positive,
/// - each tool entry must have a non-empty `name`; malformed entries
///   reject with `MoxError.invalidTools`,
/// - omitted fields fall back to `apiKey` if set, else product defaults.
public enum RequestPolicy {
    public static func resolve(_ input: ResolutionInput) throws -> ResolvedRequest {
        if input.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MoxError.invalidModelId(input.model)
        }
        let validatedTools = try validateTools(input.rawTools)

        let effectiveMessages: [ChatMessage]
        if !input.messages.isEmpty {
            effectiveMessages = input.messages
        } else if let prompt = input.prompt, !prompt.isEmpty {
            effectiveMessages = [ChatMessage(role: "user", content: prompt)]
        } else {
            throw MoxError.emptyMessages
        }

        let temperature = try resolveTemperature(input.rawTemperature, apiKey: input.apiKey)
        let topP = try resolveTopP(input.rawTopP, apiKey: input.apiKey)
        let maxTokens = try resolveMaxTokens(input.rawMaxTokens, apiKey: input.apiKey)
        let stream = input.rawStream ?? false

        let sampler = ResolvedSampler(
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            stream: stream
        )
        let modelFamilyHint: String? = nil
        return ResolvedRequest(
            model: input.model,
            messages: effectiveMessages,
            sampler: sampler,
            tools: validatedTools,
            modelFamilyHint: modelFamilyHint,
            resolvedAt: Date()
        )
    }

    private static func validateTools(_ tools: [AnyCodable]) throws -> [AnyCodable] {
        guard !tools.isEmpty else { return [] }
        var validated: [AnyCodable] = []
        for (index, tool) in tools.enumerated() {
            guard case .object(let obj) = tool else {
                throw MoxError.invalidTools(
                    reason: "tools[\(index)] must be a JSON object"
                )
            }
            guard case .string(let name) = obj["name"] ?? .null, !name.isEmpty else {
                throw MoxError.invalidTools(
                    reason: "tools[\(index)] missing required string field 'name'"
                )
            }
            validated.append(tool)
        }
        return validated
    }

    private static func resolveTemperature(
        _ raw: Double?,
        apiKey: ServerDefaults
    ) throws -> ResolvedTemperature {
        if let raw {
            try validateFinite(raw, field: "temperature")
            return ResolvedTemperature(value: raw, source: .client)
        }
        return ResolvedTemperature(value: apiKey.temperature, source: .server)
    }

    private static func resolveTopP(
        _ raw: Double?,
        apiKey: ServerDefaults
    ) throws -> ResolvedTopP {
        if let raw {
            try validateFinite(raw, field: "top_p")
            return ResolvedTopP(value: raw, source: .client)
        }
        return ResolvedTopP(value: apiKey.topP, source: .server)
    }

    private static func resolveMaxTokens(
        _ raw: Int?,
        apiKey: ServerDefaults
    ) throws -> Int {
        if let raw {
            guard raw > 0 else { throw MoxError.maxTokensOutOfRange(raw) }
            return raw
        }
        return apiKey.maxTokens
    }

    private static func validateFinite(_ value: Double, field: String) throws {
        guard value.isFinite else {
            throw MoxError.nonFiniteSampler(field: field, value: value)
        }
    }
}