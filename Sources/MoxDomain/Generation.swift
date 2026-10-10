import Foundation

public struct MoxError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
  public enum Code: String, Codable, Sendable {
    case connectionLost, protocolViolation, incompatibleService, authenticationFailed, storageFailed, serviceConflict, bodyTooLarge, notFound,
      invalidParameters, invalidModel, unsupportedInput, contextLimit, resourceLimit, busy,
      queueFull, queueTimeout, shuttingDown, slowConsumer, loadFailed, generationFailed
  }
  public let code: Code
  public let message: String
  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
  public var description: String { "\(code.rawValue): \(message)" }
}

public enum ContentBlock: Sendable, Equatable {
  case text(String)
  case toolCall(id: String, name: String, arguments: String)
  case toolResult(callID: String, text: String, isError: Bool)
  case media(assetID: String, mediaType: String)
}
public struct ToolDefinition: Sendable, Equatable {
  public let name: String
  public let description: String?
  /// Canonical JSON object. Wire-specific schemas never enter Domain.
  public let parametersJSON: String
  public init(name: String, description: String? = nil, parametersJSON: String) throws {
    guard !name.isEmpty, name.utf8.count <= 128,
      let bytes = parametersJSON.data(using: .utf8), bytes.count <= 65_536,
      let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      object["type"] as? String == "object"
    else { throw MoxError(.invalidParameters, "Invalid function tool schema.") }
    self.name = name
    self.description = description
    self.parametersJSON = parametersJSON
  }
}
public enum ToolChoice: String, Sendable { case none, auto }
public struct Message: Sendable, Equatable {
  public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
  public let role: Role
  public let content: [ContentBlock]
  public init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }
  public init(role: Role, text: String) { self.init(role: role, content: [.text(text)]) }
  public func text() throws -> String {
    guard role != .tool else {
      throw MoxError(.unsupportedInput, "This text-only request does not support tool messages.")
    }
    return try content.map { block in
      guard case .text(let text) = block else {
        throw MoxError(.unsupportedInput, "This request accepts text content only.")
      }
      return text
    }.joined()
  }
}
/// Product text-generation bounds; tokenizer validation and resource admission share them.
public enum GenerationLimits {
  public static let maximumInputTokens = 8192
  public static let maximumOutputTokens = 8192
}
public struct Sampling: Sendable, Equatable {
  public static let defaultMaxTokens = 2048
  public static let defaultTemperature: Float = 0.6
  public static let defaultTopP: Float = 1
  public let maxTokens: Int
  public let temperature: Float
  public let topP: Float
  public init(maxTokens: Int = Self.defaultMaxTokens,
    temperature: Float = Self.defaultTemperature, topP: Float = Self.defaultTopP) throws {
    guard (1...GenerationLimits.maximumOutputTokens).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature),
      topP.isFinite, topP > 0, topP <= 1
    else {
      throw MoxError(
        .invalidParameters,
        "max-tokens must be 1...8192, temperature 0...2, top-p (0,1]; numbers must be finite.")
    }
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.topP = topP
  }
}
/// A missing field inherits the next lower-priority setting. Validation happens after merging.
public struct SamplingSettings: Codable, Sendable, Equatable {
  public var maxTokens: Int?
  public var temperature: Float?
  public var topP: Float?
  public init(maxTokens: Int? = nil, temperature: Float? = nil, topP: Float? = nil) {
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.topP = topP
  }
  public init(_ sampling: Sampling) {
    self.init(maxTokens: sampling.maxTokens, temperature: sampling.temperature, topP: sampling.topP)
  }
  public func validate() throws {
    _ = try Sampling(
      maxTokens: maxTokens ?? Sampling.defaultMaxTokens,
      temperature: temperature ?? Sampling.defaultTemperature,
      topP: topP ?? Sampling.defaultTopP)
  }
}

public struct EffectiveSampling: Codable, Sendable, Equatable {
  public enum Source: String, Codable, Sendable { case request, model, launch, global, product }
  public let maxTokens: Int
  public let temperature: Float
  public let topP: Float
  public let maxTokensSource: Source
  public let temperatureSource: Source
  public let topPSource: Source
  public func sampling() throws -> Sampling {
    try Sampling(maxTokens: maxTokens, temperature: temperature, topP: topP)
  }
  public static func resolve(
    request: SamplingSettings = .init(), model: SamplingSettings = .init(),
    launch: SamplingSettings = .init(), global: SamplingSettings = .init()
  ) throws -> Self {
    func choose<T>(_ request: T?, _ model: T?, _ launch: T?, _ global: T?, _ fallback: T)
      -> (T, Source)
    {
      if let request { return (request, .request) }
      if let model { return (model, .model) }
      if let launch { return (launch, .launch) }
      if let global { return (global, .global) }
      return (fallback, .product)
    }
    let tokens = choose(request.maxTokens, model.maxTokens, launch.maxTokens,
      global.maxTokens, Sampling.defaultMaxTokens)
    let temperature = choose(request.temperature, model.temperature, launch.temperature,
      global.temperature, Sampling.defaultTemperature)
    let topP = choose(request.topP, model.topP, launch.topP, global.topP, Sampling.defaultTopP)
    _ = try Sampling(maxTokens: tokens.0, temperature: temperature.0, topP: topP.0)
    return Self(maxTokens: tokens.0, temperature: temperature.0, topP: topP.0,
      maxTokensSource: tokens.1, temperatureSource: temperature.1, topPSource: topP.1)
  }
}
public struct GenerationRequest: Sendable {
  public static let maximumInputBytes = 1_048_576
  public let id: UUID
  public let messages: [Message]
  public let sampling: Sampling
  public let stopSequences: [String]
  public let tools: [ToolDefinition]
  public let toolChoice: ToolChoice
  public func replacingSampling(_ value: Sampling) throws -> GenerationRequest {
    try GenerationRequest(id: id, messages: messages, sampling: value,
      stopSequences: stopSequences, tools: tools, toolChoice: toolChoice)
  }
  public init(id: UUID = UUID(), messages: [Message], sampling: Sampling,
    stopSequences: [String] = [], tools: [ToolDefinition] = [], toolChoice: ToolChoice = .none) throws {
    guard !messages.isEmpty else {
      throw MoxError(.invalidParameters, "At least one message is required.")
    }
    guard stopSequences.count <= 4, stopSequences.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
      tools.count <= 32, Set(tools.map(\.name)).count == tools.count,
      toolChoice == .none || !tools.isEmpty
    else { throw MoxError(.invalidParameters, "Invalid stop sequences or tools.") }
    var pending = Set<String>()
    var usedCallIDs = Set<String>()
    for message in messages {
      let hasToolResult = message.content.contains { block in
        if case .toolResult = block { return true }
        return false
      }
      if !pending.isEmpty {
        guard (message.role == .tool || message.role == .user), hasToolResult
        else { throw MoxError(.invalidParameters, "Tool results must immediately follow their assistant calls.") }
      }
      for block in message.content {
        switch block {
        case .text: guard message.role != .tool else { throw MoxError(.unsupportedInput, "Tool messages require a call ID.") }
        case .toolCall(let id, _, let arguments):
          guard message.role == .assistant, !id.isEmpty, !usedCallIDs.contains(id),
            let data = arguments.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
          else { throw MoxError(.invalidParameters, "Invalid assistant tool call.") }
          pending.insert(id)
          usedCallIDs.insert(id)
        case .toolResult(let callID, _, _):
          guard message.role == .tool || message.role == .user, pending.remove(callID) != nil
          else { throw MoxError(.invalidParameters, "Tool result has no pending call.") }
        case .media: throw MoxError(.unsupportedInput, "Media input is not supported.")
        }
      }
      if message.role == .user, hasToolResult, !pending.isEmpty {
        throw MoxError(.invalidParameters, "All tool results must be in the same user turn.")
      }
    }
    guard pending.isEmpty else { throw MoxError(.invalidParameters, "Tool results are missing.") }
    guard
      messages.reduce(
        0,
        {
          $0
            + $1.content.reduce(
              0,
              { total, block in
                switch block {
                case .text(let text): return total + text.utf8.count
                case .toolCall(let id, let name, let arguments): return total + id.utf8.count + name.utf8.count + arguments.utf8.count
                case .toolResult(let id, let text, _): return total + id.utf8.count + text.utf8.count
                case .media: return total
                }
              })
        }) <= Self.maximumInputBytes
    else {
      throw MoxError(.contextLimit, "Input exceeds the 1 MiB safety limit.")
    }
    self.id = id
    self.messages = messages
    self.sampling = sampling
    self.stopSequences = stopSequences
    self.tools = tools
    self.toolChoice = toolChoice
  }
}
public enum FinishReason: String, Codable, Sendable {
  case stop, stopSequence, length, toolCalls, cancelled
  public var includesTurnInContext: Bool { self != .cancelled }
}
public struct Usage: Codable, Sendable {
  public let promptTokens: Int
  public let outputTokens: Int
  public let prefillSeconds: Double
  public let decodeSeconds: Double
  public let peakMemoryBytes: Int?
  public init(promptTokens: Int, outputTokens: Int, prefillSeconds: Double, decodeSeconds: Double, peakMemoryBytes: Int? = nil) {
    self.promptTokens = promptTokens
    self.outputTokens = outputTokens
    self.prefillSeconds = prefillSeconds
    self.decodeSeconds = decodeSeconds
    self.peakMemoryBytes = peakMemoryBytes
  }
}
public enum GenerationPayload: Sendable {
  case phase(String)
  case promptTokens(Int)
  case contentDelta(String)
  case toolCall(id: String, name: String, arguments: String)
  case matchedStopSequence(String)
  case usage(Usage)
  case finished(FinishReason)
  case failed(MoxError)
  public var isTerminal: Bool {
    switch self {
    case .finished, .failed: true
    default: false
    }
  }
}
public struct GenerationEvent: Sendable {
  public let requestID: UUID
  public let sequence: Int
  public let payload: GenerationPayload
  public init(requestID: UUID, sequence: Int, payload: GenerationPayload) {
    self.requestID = requestID
    self.sequence = sequence
    self.payload = payload
  }
}

/// Session history is distinct from a generation. Partial/failed answers never enter history.
public struct ChatSession: Sendable {
  public private(set) var messages: [Message] = []
  public init() {}
  public func request(prompt: String, sampling: Sampling) throws -> GenerationRequest {
    try GenerationRequest(
      messages: messages + [.init(role: .user, text: prompt)], sampling: sampling)
  }
  public mutating func complete(prompt: String, reply: String, reason: FinishReason) {
    guard reason.includesTurnInContext else { return }
    messages += [.init(role: .user, text: prompt), .init(role: .assistant, text: reply)]
  }
}
