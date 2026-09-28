import Foundation
import MoxDomain

/// One response encoder per HTTP request. It never stores a second unbounded event queue.
struct PublicResponse {
  let call: PublicCall
  let identifier: String
  let created: Int
  private(set) var text = ""
  private(set) var toolCalls: [(id: String, name: String, arguments: String)] = []
  private var orderedBlocks: [[String: Any]] = []
  private(set) var usage: Usage?
  private(set) var reason: FinishReason?
  private(set) var stopSequence: String?
  private var started = false
  private var nextBlock = 0
  private var activeTextBlock: Int?
  private var inputTokens: Int?

  init(call: PublicCall) {
    self.call = call
    identifier = (call.dialect == .openAI ? "chatcmpl_" : "msg_") + call.request.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    created = Int(Date().timeIntervalSince1970)
  }
  private func json(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  private func frame(_ object: [String: Any], event: String? = nil) throws -> Data {
    var bytes = Data()
    if let event { bytes.append(Data("event: \(event)\n".utf8)) }
    bytes.append(Data("data: ".utf8))
    bytes.append(try json(object))
    bytes.append(Data("\n\n".utf8))
    return bytes
  }
  private func openAIChunk(_ delta: [String: Any], finish: String? = nil, empty: Bool = false,
    usage: [String: Any]? = nil) -> [String: Any] {
    ["id": identifier, "object": "chat.completion.chunk", "created": created,
      "model": call.model, "choices": empty ? [] : [["index": 0, "delta": delta,
        "finish_reason": finish as Any? ?? NSNull(), "logprobs": NSNull()]],
      "usage": usage as Any? ?? NSNull()]
  }
  mutating func accept(_ event: GenerationEvent) throws -> [Data] {
    var bytes: [Data] = []
    switch event.payload {
    case .phase: break
    case .promptTokens(let count):
      inputTokens = count
      if call.dialect == .anthropic && !started {
        started = true
        bytes.append(try frame(["type": "message_start", "message": [
          "id": identifier, "type": "message", "role": "assistant", "model": call.model,
          "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
          "usage": ["input_tokens": count, "output_tokens": 0]]], event: "message_start"))
      }
    case .contentDelta(let part):
      text += part
      if orderedBlocks.last?["type"] as? String == "text" {
        orderedBlocks[orderedBlocks.count - 1]["text"] =
          (orderedBlocks.last?["text"] as? String ?? "") + part
      } else {
        orderedBlocks.append(["type": "text", "text": part])
      }
      if call.dialect == .openAI {
        if !started {
          started = true
          bytes.append(try frame(openAIChunk(["role": "assistant", "content": ""])))
        }
        bytes.append(try frame(openAIChunk(["content": part])))
      } else {
        guard started else { throw MoxError(.protocolViolation, "Missing prompt usage before output.") }
        if activeTextBlock == nil {
          activeTextBlock = nextBlock
          bytes.append(try frame(["type": "content_block_start", "index": nextBlock,
            "content_block": ["type": "text", "text": ""]], event: "content_block_start"))
          nextBlock += 1
        }
        bytes.append(try frame(["type": "content_block_delta", "index": activeTextBlock!,
          "delta": ["type": "text_delta", "text": part]], event: "content_block_delta"))
      }
    case .toolCall(let id, let name, let arguments):
      toolCalls.append((id, name, arguments))
      guard let input = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
        throw MoxError(.generationFailed, "Model tool arguments are not a JSON object.")
      }
      orderedBlocks.append(["type": "tool_use", "id": id, "name": name, "input": input])
      if call.dialect == .openAI {
        if !started {
          started = true
          bytes.append(try frame(openAIChunk(["role": "assistant", "content": NSNull()])))
        }
        let index = toolCalls.count - 1
        bytes.append(try frame(openAIChunk(["tool_calls": [["index": index, "id": id,
          "type": "function", "function": ["name": name, "arguments": ""]]]])))
        for part in arguments.chunks(maximum: 64) {
          bytes.append(try frame(openAIChunk(["tool_calls": [["index": index,
            "function": ["arguments": part]]]])))
        }
      } else {
        guard started else { throw MoxError(.protocolViolation, "Missing prompt usage before tool call.") }
        if let index = activeTextBlock {
          bytes.append(try frame(["type": "content_block_stop", "index": index], event: "content_block_stop"))
          activeTextBlock = nil
        }
        let index = nextBlock
        nextBlock += 1
        bytes.append(try frame(["type": "content_block_start", "index": index,
          "content_block": ["type": "tool_use", "id": id, "name": name, "input": [:]]], event: "content_block_start"))
        for part in arguments.chunks(maximum: 64) {
          bytes.append(try frame(["type": "content_block_delta", "index": index,
            "delta": ["type": "input_json_delta", "partial_json": part]], event: "content_block_delta"))
        }
        bytes.append(try frame(["type": "content_block_stop", "index": index], event: "content_block_stop"))
      }
    case .matchedStopSequence(let value): stopSequence = value
    case .usage(let value): usage = value
    case .finished(let value):
      reason = value
      guard value != .cancelled, let usage else {
        throw MoxError(.generationFailed, "Generation stopped without complete usage.")
      }
      if call.dialect == .openAI {
        if !started { bytes.append(try frame(openAIChunk(["role": "assistant", "content": ""]))) }
        let finish = value == .toolCalls ? "tool_calls" : value == .length ? "length" : "stop"
        bytes.append(try frame(openAIChunk([:], finish: finish)))
        if call.includeUsage {
          bytes.append(try frame(openAIChunk([:], empty: true, usage: [
            "prompt_tokens": usage.promptTokens, "completion_tokens": usage.outputTokens,
            "total_tokens": usage.promptTokens + usage.outputTokens])))
        }
        bytes.append(Data("data: [DONE]\n\n".utf8))
      } else {
        if !started { throw MoxError(.protocolViolation, "Missing message_start.") }
        if let index = activeTextBlock {
          bytes.append(try frame(["type": "content_block_stop", "index": index], event: "content_block_stop"))
          activeTextBlock = nil
        }
        let reason = value == .toolCalls ? "tool_use" : value == .length ? "max_tokens" : value == .stopSequence ? "stop_sequence" : "end_turn"
        bytes.append(try frame(["type": "message_delta", "delta": ["stop_reason": reason,
          "stop_sequence": stopSequence as Any? ?? NSNull()], "usage": ["output_tokens": usage.outputTokens]], event: "message_delta"))
        bytes.append(try frame(["type": "message_stop"], event: "message_stop"))
      }
    case .failed(let error): throw error
    }
    return bytes
  }
  func complete() throws -> Data {
    guard let reason, reason != .cancelled, let usage else {
      throw MoxError(.generationFailed, "Generation did not finish with usage.")
    }
    if call.dialect == .anthropic {
      let stop = reason == .toolCalls ? "tool_use" : reason == .length ? "max_tokens" : reason == .stopSequence ? "stop_sequence" : "end_turn"
      return try json(["id": identifier, "type": "message", "role": "assistant", "model": call.model,
        "content": orderedBlocks, "stop_reason": stop, "stop_sequence": stopSequence as Any? ?? NSNull(),
        "usage": ["input_tokens": usage.promptTokens, "output_tokens": usage.outputTokens]])
    }
    let calls: [[String: Any]] = toolCalls.map { ["id": $0.id, "type": "function",
      "function": ["name": $0.name, "arguments": $0.arguments]] }
    let message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text as Any,
      "tool_calls": calls.isEmpty ? NSNull() : calls as Any]
    return try json(["id": identifier, "object": "chat.completion", "created": created,
      "model": call.model, "choices": [["index": 0, "message": message,
        "finish_reason": reason == .toolCalls ? "tool_calls" : reason == .length ? "length" : "stop",
        "logprobs": NSNull()]], "usage": ["prompt_tokens": usage.promptTokens,
          "completion_tokens": usage.outputTokens, "total_tokens": usage.promptTokens + usage.outputTokens]])
  }
  static func error(_ error: MoxError, dialect: PublicDialect) -> Data {
    let type = error.code == .authenticationFailed ? "authentication_error" :
      error.code == .notFound ? "not_found_error" :
      error.code == .queueFull || error.code == .queueTimeout ? "rate_limit_error" :
      error.code == .resourceLimit || error.code == .shuttingDown ? "overloaded_error" :
      error.code == .generationFailed || error.code == .loadFailed ? "api_error" : "invalid_request_error"
    let code = error.code == .resourceLimit ? "resource_exhausted" : error.code.rawValue
    let object: [String: Any] = dialect == .anthropic
      ? ["type": "error", "error": ["type": type, "message": error.message],
        "request_id": "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()]
      : ["error": ["type": type, "message": error.message,
          "param": NSNull(), "code": code]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
  }
  static func streamError(_ error: MoxError, dialect: PublicDialect) -> Data {
    let data = Self.error(error, dialect: dialect)
    return Data((dialect == .anthropic ? "event: error\n" : "").utf8)
      + Data("data: ".utf8) + data + Data("\n\n".utf8)
  }
}
private extension String {
  func chunks(maximum: Int) -> [String] {
    guard !isEmpty else { return [""] }
    let characters = Array(self)
    return stride(from: 0, to: characters.count, by: maximum).map {
      String(characters[$0..<min($0 + maximum, characters.count)])
    }
  }
}
