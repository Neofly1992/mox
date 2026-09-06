import Foundation

public struct MoxError: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Code: String, Sendable {
    case invalidParameters, invalidModel, unsupportedInput, contextLimit, resourceLimit, busy,
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
  case toolResult(callID: String, text: String)
  case media(assetID: String, mediaType: String)
}
public struct Message: Sendable, Equatable {
  public enum Role: String, Sendable { case system, user, assistant, tool }
  public let role: Role
  public let content: [ContentBlock]
  public init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }
  public init(role: Role, text: String) { self.init(role: role, content: [.text(text)]) }
  public func text() throws -> String {
    guard role != .tool else {
      throw MoxError(.unsupportedInput, "M1 does not support tool messages.")
    }
    return try content.map { block in
      guard case .text(let text) = block else {
        throw MoxError(.unsupportedInput, "M1 accepts text content only.")
      }
      return text
    }.joined()
  }
}
public struct Sampling: Sendable, Equatable {
  public let maxTokens: Int
  public let temperature: Float
  public let topP: Float
  public init(maxTokens: Int = 2048, temperature: Float = 0.6, topP: Float = 1) throws {
    guard (1...8192).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature),
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
public struct GenerationRequest: Sendable {
  public let id: UUID
  public let messages: [Message]
  public let sampling: Sampling
  public init(id: UUID = UUID(), messages: [Message], sampling: Sampling) throws {
    guard !messages.isEmpty else {
      throw MoxError(.invalidParameters, "At least one message is required.")
    }
    for message in messages { _ = try message.text() }
    guard
      messages.reduce(
        0,
        {
          $0
            + $1.content.reduce(
              0,
              { total, block in
                if case .text(let text) = block { return total + text.utf8.count }
                return total
              })
        }) <= 1_048_576
    else {
      throw MoxError(.contextLimit, "Input exceeds the 1 MiB safety limit.")
    }
    self.id = id
    self.messages = messages
    self.sampling = sampling
  }
}
public enum FinishReason: String, Sendable { case stop, length, cancelled }
public struct Usage: Sendable {
  public let promptTokens: Int
  public let outputTokens: Int
  public let prefillSeconds: Double
  public let decodeSeconds: Double
  public init(promptTokens: Int, outputTokens: Int, prefillSeconds: Double, decodeSeconds: Double) {
    self.promptTokens = promptTokens
    self.outputTokens = outputTokens
    self.prefillSeconds = prefillSeconds
    self.decodeSeconds = decodeSeconds
  }
}
public enum GenerationPayload: Sendable {
  case phase(String)
  case contentDelta(String)
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
    guard reason != .cancelled else { return }
    messages += [.init(role: .user, text: prompt), .init(role: .assistant, text: reply)]
  }
}
