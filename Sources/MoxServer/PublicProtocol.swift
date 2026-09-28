import Foundation
import MoxDomain

/// Wire-only parsing and encoding. Core never depends on provider DTOs.
enum PublicDialect: Sendable { case openAI, anthropic }
struct PublicCall: Sendable {
  let dialect: PublicDialect
  let model: String
  let request: GenerationRequest
  let stream: Bool
  let includeUsage: Bool
}

enum PublicProtocol {
  private static func object(_ value: Any?, _ allowed: Set<String>, at path: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw MoxError(.invalidParameters, "Expected object at \(path).")
    }
    guard let unknown = Set(value.keys).subtracting(allowed).sorted().first else { return value }
    throw MoxError(.unsupportedInput, "Unsupported field \(path).\(unknown).")
  }
  private static func string(_ value: Any?, at path: String) throws -> String {
    guard let value = value as? String else { throw MoxError(.invalidParameters, "Expected text at \(path).") }
    return value
  }
  private static func array(_ value: Any?, at path: String) throws -> [Any] {
    guard let value = value as? [Any] else { throw MoxError(.invalidParameters, "Expected array at \(path).") }
    return value
  }
  private static func bool(_ value: Any?, at path: String) throws -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw MoxError(.invalidParameters, "Expected boolean at \(path).")
    }
    return number.boolValue
  }
  private static func int(_ value: Any?, at path: String) throws -> Int {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      let result = Int(exactly: number.int64Value) else {
      throw MoxError(.invalidParameters, "Expected integer at \(path).")
    }
    return result
  }
  private static func float(_ value: Any?, at path: String) throws -> Float {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite else {
      throw MoxError(.invalidParameters, "Expected number at \(path).")
    }
    return number.floatValue
  }
  private static func json(_ value: Any) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else { throw MoxError(.invalidParameters, "Expected JSON object.") }
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }
  private static func text(_ value: Any?, at path: String) throws -> String {
    if let value = value as? String { return value }
    return try array(value, at: path).enumerated().map { index, item in
      let block = try object(item, ["type", "text"], at: "\(path)[\(index)]")
      guard try string(block["type"], at: path) == "text" else {
        throw MoxError(.unsupportedInput, "Only text blocks are available at \(path).")
      }
      return try string(block["text"], at: path)
    }.joined()
  }
  private static func stops(_ value: Any?, at path: String) throws -> [String] {
    guard let value else { return [] }
    if let single = value as? String { return [single] }
    return try array(value, at: path).map { try string($0, at: path) }
  }
  private static func choice(_ value: Any?, at path: String, anthropic: Bool) throws -> ToolChoice? {
    guard let value else { return nil }
    let name: String
    if anthropic {
      name = try string(object(value, ["type"], at: path)["type"], at: path)
    } else {
      name = try string(value, at: path)
    }
    guard let result = ToolChoice(rawValue: name) else {
      throw MoxError(.unsupportedInput, "Unsupported \(path) value.")
    }
    return result
  }
  private static func tools(_ value: Any?, anthropic: Bool) throws -> [ToolDefinition] {
    guard let value else { return [] }
    return try array(value, at: "tools").enumerated().map { index, item in
      let path = "tools[\(index)]"
      let raw: [String: Any]
      if anthropic {
        raw = try object(item, ["name", "description", "input_schema"], at: path)
      } else {
        let wrapper = try object(item, ["type", "function"], at: path)
        guard try string(wrapper["type"], at: "\(path).type") == "function" else {
          throw MoxError(.unsupportedInput, "Only function tools are supported.")
        }
        raw = try object(wrapper["function"], ["name", "description", "parameters"], at: "\(path).function")
      }
      guard let parameters = raw[anthropic ? "input_schema" : "parameters"] as? [String: Any] else {
        throw MoxError(.invalidParameters, "Expected object at \(path).schema.")
      }
      return try ToolDefinition(name: string(raw["name"], at: "\(path).name"),
        description: raw["description"].map { try string($0, at: "\(path).description") },
        parametersJSON: json(parameters))
    }
  }
  static func parse(_ data: Data, dialect: PublicDialect) throws -> PublicCall {
    let value: Any
    do { value = try JSONSerialization.jsonObject(with: data) }
    catch { throw MoxError(.invalidParameters, "Invalid JSON request.") }
    switch dialect {
    case .openAI: return try openAI(value)
    case .anthropic: return try anthropic(value)
    }
  }
  private static func openAI(_ value: Any) throws -> PublicCall {
    let root = try object(value, ["model", "messages", "stream", "temperature", "top_p", "max_tokens", "stop", "tools", "tool_choice", "stream_options", "n", "parallel_tool_calls", "response_format"], at: "request")
    let model = try string(root["model"], at: "model")
    guard try root["n"] == nil || int(root["n"], at: "n") == 1 else {
      throw MoxError(.unsupportedInput, "Only n=1 is supported.")
    }
    guard try root["parallel_tool_calls"] == nil || !bool(root["parallel_tool_calls"], at: "parallel_tool_calls") else {
      throw MoxError(.unsupportedInput, "Parallel tool calls are unsupported.")
    }
    if let format = root["response_format"] {
      let object = try object(format, ["type"], at: "response_format")
      guard try string(object["type"], at: "response_format.type") == "text" else {
        throw MoxError(.unsupportedInput, "Only text response_format is supported.")
      }
    }
    let stream = try root["stream"].map { try bool($0, at: "stream") } ?? false
    let options = try root["stream_options"].map { try object($0, ["include_usage"], at: "stream_options") }
    guard stream || options == nil else { throw MoxError(.invalidParameters, "stream_options requires stream=true.") }
    let includeUsage = try options?["include_usage"].map { try bool($0, at: "include_usage") } ?? false
    let definitions = try tools(root["tools"], anthropic: false)
    let selected = try choice(root["tool_choice"], at: "tool_choice", anthropic: false)
      ?? (definitions.isEmpty ? .none : .auto)
    let entries = try array(root["messages"], at: "messages")
    let messages = try entries.enumerated().map { index, entry -> Message in
      let path = "messages[\(index)]"
      let message = try object(entry, ["role", "content", "tool_calls", "tool_call_id"], at: path)
      let role = try string(message["role"], at: "\(path).role")
      if role == "tool" {
        guard message["tool_calls"] == nil else {
          throw MoxError(.unsupportedInput, "tool_calls is invalid at \(path).")
        }
        let callID = try string(message["tool_call_id"], at: "\(path).tool_call_id")
        return Message(role: .tool, content: [.toolResult(callID: callID,
          text: try text(message["content"], at: "\(path).content"), isError: false)])
      }
      guard let domainRole = Message.Role(rawValue: role), domainRole != .tool else {
        throw MoxError(.unsupportedInput, "Unsupported message role at \(path).")
      }
      guard message["tool_call_id"] == nil else {
        throw MoxError(.unsupportedInput, "tool_call_id is invalid at \(path).")
      }
      var blocks: [ContentBlock] = []
      if let content = message["content"], !(content is NSNull) {
        blocks.append(.text(try text(content, at: "\(path).content")))
      }
      if let calls = message["tool_calls"] {
        guard role == "assistant" else { throw MoxError(.invalidParameters, "tool_calls require assistant role.") }
        for (callIndex, item) in try array(calls, at: "\(path).tool_calls").enumerated() {
          let call = try object(item, ["id", "type", "function"], at: "\(path).tool_calls[\(callIndex)]")
          guard try string(call["type"], at: "tool.type") == "function" else {
            throw MoxError(.unsupportedInput, "Only function tool calls are supported.")
          }
          let function = try object(call["function"], ["name", "arguments"], at: "tool.function")
          blocks.append(.toolCall(id: try string(call["id"], at: "tool.id"),
            name: try string(function["name"], at: "tool.name"),
            arguments: try string(function["arguments"], at: "tool.arguments")))
        }
      }
      return Message(role: domainRole, content: blocks)
    }
    let sampling = try Sampling(maxTokens: root["max_tokens"].map { try int($0, at: "max_tokens") } ?? 2048,
      temperature: root["temperature"].map { try float($0, at: "temperature") } ?? 0.6,
      topP: root["top_p"].map { try float($0, at: "top_p") } ?? 1)
    return PublicCall(dialect: .openAI, model: model,
      request: try GenerationRequest(messages: messages, sampling: sampling,
        stopSequences: stops(root["stop"], at: "stop"), tools: definitions, toolChoice: selected),
      stream: stream, includeUsage: includeUsage)
  }
  private static func anthropic(_ value: Any) throws -> PublicCall {
    let root = try object(value, ["model", "messages", "system", "max_tokens", "stream", "temperature", "top_p", "stop_sequences", "tools", "tool_choice"], at: "request")
    let model = try string(root["model"], at: "model")
    var messages: [Message] = []
    if let system = root["system"] { messages.append(.init(role: .system,
      text: try text(system, at: "system"))) }
    for (index, item) in try array(root["messages"], at: "messages").enumerated() {
      let path = "messages[\(index)]"
      let entry = try object(item, ["role", "content"], at: path)
      let role = try string(entry["role"], at: "\(path).role")
      guard role == "user" || role == "assistant" else {
        throw MoxError(.unsupportedInput, "Unsupported role at \(path).")
      }
      let blocks: [ContentBlock]
      if let plain = entry["content"] as? String { blocks = [.text(plain)] }
      else {
        blocks = try array(entry["content"], at: "\(path).content").enumerated().map { blockIndex, item in
          let blockPath = "\(path).content[\(blockIndex)]"
          let block = try object(item, ["type", "text", "id", "name", "input", "tool_use_id", "content", "is_error"], at: blockPath)
          switch try string(block["type"], at: "\(blockPath).type") {
          case "text":
            _ = try object(block, ["type", "text"], at: blockPath)
            return .text(try string(block["text"], at: "\(blockPath).text"))
          case "tool_use" where role == "assistant":
            _ = try object(block, ["type", "id", "name", "input"], at: blockPath)
            let input = try object(block["input"], Set((block["input"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys), at: "\(blockPath).input")
            return .toolCall(id: try string(block["id"], at: "\(blockPath).id"),
              name: try string(block["name"], at: "\(blockPath).name"), arguments: try json(input))
          case "tool_result" where role == "user":
            _ = try object(block, ["type", "tool_use_id", "content", "is_error"], at: blockPath)
            return .toolResult(callID: try string(block["tool_use_id"], at: "\(blockPath).tool_use_id"),
              text: try text(block["content"], at: "\(blockPath).content"),
              isError: try block["is_error"].map { try bool($0, at: "\(blockPath).is_error") } ?? false)
          default: throw MoxError(.unsupportedInput, "Unsupported content at \(blockPath).")
          }
        }
      }
      messages.append(Message(role: role == "user" ? .user : .assistant, content: blocks))
    }
    let definitions = try tools(root["tools"], anthropic: true)
    let selected = try choice(root["tool_choice"], at: "tool_choice", anthropic: true)
      ?? (definitions.isEmpty ? .none : .auto)
    let sampling = try Sampling(maxTokens: int(root["max_tokens"], at: "max_tokens"),
      temperature: root["temperature"].map { try float($0, at: "temperature") } ?? 0.6,
      topP: root["top_p"].map { try float($0, at: "top_p") } ?? 1)
    return PublicCall(dialect: .anthropic, model: model,
      request: try GenerationRequest(messages: messages, sampling: sampling,
        stopSequences: stops(root["stop_sequences"], at: "stop_sequences"),
        tools: definitions, toolChoice: selected), stream: try root["stream"].map { try bool($0, at: "stream") } ?? false,
      includeUsage: true)
  }
}
