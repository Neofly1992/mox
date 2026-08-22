import Foundation

/// OpenAI `/v1/embeddings` request shape. v0.8 ships the wire contract;
/// the actual inference path returns 501 Not Implemented until the MLX
/// embedder actor lands in v0.9.
public struct EmbeddingRequest: Codable, Sendable {
    public let model: String
    /// String or array of strings. v0.8 only accepts plain strings; an
    /// array is decoded but the handler returns 501.
    public let input: EmbeddingInput
    public let encodingFormat: String?
    public let dimensions: Int?
    public let user: String?

    enum CodingKeys: String, CodingKey {
        case model, input, user
        case encodingFormat = "encoding_format"
        case dimensions
    }

    public init(
        model: String,
        input: EmbeddingInput,
        encodingFormat: String? = nil,
        dimensions: Int? = nil,
        user: String? = nil
    ) {
        self.model = model
        self.input = input
        self.encodingFormat = encodingFormat
        self.dimensions = dimensions
        self.user = user
    }
}

/// Permissive decoder for the `input` field — accepts a string or
/// `[String]` payload so the wire shape matches OpenAI.
public enum EmbeddingInput: Codable, Sendable, Equatable {
    case single(String)
    case batch([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .single(s); return
        }
        let arr = try container.decode([String].self)
        self = .batch(arr)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .batch(let arr): try container.encode(arr)
        }
    }

    /// Number of texts this request will embed.
    public var count: Int {
        switch self {
        case .single: return 1
        case .batch(let arr): return arr.count
        }
    }
}

/// `/v1/embeddings` response shape — mirrors OpenAI's `{object, data, model, usage}`.
public struct EmbeddingResponse: Codable, Sendable {
    public let object: String
    public let data: [EmbeddingEntry]
    public let model: String
    public let usage: EmbeddingUsage

    public init(
        object: String = "list",
        data: [EmbeddingEntry],
        model: String,
        usage: EmbeddingUsage
    ) {
        self.object = object
        self.data = data
        self.model = model
        self.usage = usage
    }
}

public struct EmbeddingEntry: Codable, Sendable {
    public let object: String
    public let embedding: [Double]
    public let index: Int

    public init(object: String = "embedding", embedding: [Double], index: Int) {
        self.object = object
        self.embedding = embedding
        self.index = index
    }
}

public struct EmbeddingUsage: Codable, Sendable {
    public let promptTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }

    public init(promptTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.totalTokens = totalTokens
    }
}

/// Error envelope returned by the embedding endpoint when the feature
/// isn't wired up. Kept as a structured 501 instead of a generic 500
/// so client SDKs can branch on the `code`.
public struct EmbeddingNotImplementedError: Codable, Sendable {
    public struct ErrorBody: Codable, Sendable {
        public let message: String
        public let type: String
        public let code: String
        public init(message: String, type: String, code: String) {
            self.message = message
            self.type = type
            self.code = code
        }
    }
    public let error: ErrorBody
    public init(error: ErrorBody) { self.error = error }

    public static let notImplemented = ErrorBody(
        message: "embeddings are not implemented in this Mox build (v0.8). Use v0.9+.",
        type: "server_error",
        code: "embeddings_not_implemented"
    )
}