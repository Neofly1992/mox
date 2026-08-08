import Foundation

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
/// successful pull. Records the canonical model id, the source, the originally
/// requested id, and the install timestamp. The manifest is the source of
/// truth for `source` so that callers never have to reverse-engineer it from
/// the directory name.
public struct ModelManifest: Codable, Sendable {
    public var id: String
    public var source: ModelSource
    public var originalId: String
    public var installedAt: Date

    public init(id: String, source: ModelSource, originalId: String, installedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.originalId = originalId
        self.installedAt = installedAt
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
        public var port: Int = 8080
        
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
    
    public init(model: String, messages: [ChatMessage], maxTokens: Int? = nil, temperature: Double? = nil, topP: Double? = nil, stream: Bool? = nil) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stream = stream
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
        
        public init(role: String = "assistant", content: String) {
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
}

public protocol ModelSourceResolver: Sendable {
    var name: String { get }
    func resolveModelId(_ id: String) -> String
    func downloadURL(for modelId: String) -> URL?
    /// Validate that any configured mirror host is on this source's allowlist.
    /// Throws `MirrorError.invalidMirror` if a mirror is set to a non-allowed host.
    func validateMirror() throws
}

/// Error raised when a configured mirror host is not on the source's allowlist.
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
