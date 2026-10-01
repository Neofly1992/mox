import Foundation
import MoxCore
import MoxDomain
@testable import MoxServer
import Testing

private func body(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value)
}

@Test func publicSamplingKeepsOnlyExplicitFields() throws {
  let base: [String: Any] = ["model": "fixture",
    "messages": [["role": "user", "content": "hello"]]]
  let inherited = try PublicProtocol.parse(body(base), dialect: .openAI)
  #expect(inherited.explicitSampling == SamplingSettings())
  var specified = base
  specified["temperature"] = 0
  specified["top_p"] = 0.7
  let parsed = try PublicProtocol.parse(body(specified), dialect: .openAI)
  #expect(parsed.explicitSampling.maxTokens == nil)
  #expect(parsed.explicitSampling.temperature == 0)
  #expect(parsed.explicitSampling.topP == 0.7)
}

@Test func publicProtocolRejectsUnsupportedSemanticsAndPreservesSchema() throws {
  let schema: [String: Any] = ["type": "object", "properties": ["code": ["type": "string", "enum": ["MOX-7"]]], "required": ["code"]]
  let base: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "lookup"]],
    "tools": [["type": "function", "function": ["name": "lookup_code", "parameters": schema]]]]
  let parsed = try PublicProtocol.parse(body(base), dialect: .openAI)
  #expect(parsed.request.toolChoice == .auto)
  #expect(parsed.request.tools[0].parametersJSON.contains("enum"))
  var unsupported = base
  unsupported["seed"] = 1
  #expect(throws: MoxError.self) { try PublicProtocol.parse(body(unsupported), dialect: .openAI) }
  unsupported = base
  unsupported["tool_choice"] = "required"
  #expect(throws: MoxError.self) { try PublicProtocol.parse(body(unsupported), dialect: .openAI) }
  unsupported = base
  unsupported["tools"] = [["type": "function", "function": ["name": "lookup_code",
    "description": 7, "parameters": schema]]]
  #expect(throws: MoxError.self) { try PublicProtocol.parse(body(unsupported), dialect: .openAI) }
}

@Test func toolCapabilityRequiresPinnedArtifactEvidence() {
  let origin = ArtifactOrigin(registryID: UUID(), repository: "mlx-community/Qwen3-0.6B-4bit",
    revision: "73e3e38d981303bc594367cd910ea6eb48349da8")
  let weight = ArtifactFile(path: "model.safetensors", bytes: 335450584,
    digest: .sha256("392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2"))
  let tokenizer = ArtifactFile(path: "tokenizer.json", bytes: 11422654,
    digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"))
  #expect(!VerifiedToolModel.supports(.init(path: "/tmp/unverified", manifest: nil, alias: "imported")))
  #expect(VerifiedToolModel.supports(.init(path: "/tmp/verified",
    manifest: .init(origin: origin, files: [weight, tokenizer]), alias: "verified")))
  let different = ModelInstallation(path: "/tmp/different",
    manifest: .init(origin: .init(registryID: origin.registryID,
      repository: origin.repository, revision: "other"), files: [weight, tokenizer]), alias: "other")
  #expect(VerifiedToolModel.supports(different) == false)
}

@Test func publicErrorsExposeStableCapacityAndRateLimitCodes() throws {
  let limited = try #require(JSONSerialization.jsonObject(with:
    PublicResponse.error(MoxError(.resourceLimit, "Memory limit."), dialect: .openAI)) as? [String: Any])
  let limitedError = try #require(limited["error"] as? [String: Any])
  #expect(limitedError["code"] as? String == "resource_exhausted")
  let timedOut = try #require(JSONSerialization.jsonObject(with:
    PublicResponse.error(MoxError(.queueTimeout, "Queue timed out."), dialect: .anthropic)) as? [String: Any])
  let timedOutError = try #require(timedOut["error"] as? [String: Any])
  #expect(timedOutError["type"] as? String == "rate_limit_error")
}

@Test func publicProtocolChecksToolHistory() throws {
  let valid: [String: Any] = ["model": "fixture", "messages": [
    ["role": "user", "content": "lookup"],
    ["role": "assistant", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "lookup_code", "arguments": "{\"code\":\"MOX-7\"}"]]]],
    ["role": "tool", "tool_call_id": "call_1", "content": "blue"]]]
  _ = try PublicProtocol.parse(body(valid), dialect: .openAI)
  var invalid = valid
  invalid["messages"] = Array((valid["messages"] as! [[String: Any]]).dropLast())
  #expect(throws: MoxError.self) { try PublicProtocol.parse(body(invalid), dialect: .openAI) }
}

@Test func openAIToolResultsCannotCrossConversationTurns() throws {
  let call: [String: Any] = ["id": "call_1", "type": "function",
    "function": ["name": "lookup_code", "arguments": "{}"]]
  let secondCall: [String: Any] = ["id": "call_2", "type": "function",
    "function": ["name": "lookup_code", "arguments": "{}"]]
  let assistant: [String: Any] = ["role": "assistant", "tool_calls": [call, secondCall]]
  let firstResult: [String: Any] = ["role": "tool", "tool_call_id": "call_1", "content": "blue"]
  let secondResult: [String: Any] = ["role": "tool", "tool_call_id": "call_2", "content": "green"]
  let prefix: [[String: Any]] = [["role": "user", "content": "lookup"], assistant, firstResult]
  func parse(_ messages: [[String: Any]]) throws -> PublicCall {
    try PublicProtocol.parse(body(["model": "fixture", "messages": messages]), dialect: .openAI)
  }
  _ = try parse(prefix + [secondResult, ["role": "user", "content": "continue"]])
  #expect(throws: MoxError.self) {
    try parse(prefix + [["role": "user", "content": "unrelated"], secondResult])
  }
  #expect(throws: MoxError.self) {
    try parse([["role": "user", "content": "lookup"], assistant,
      ["role": "user", "content": "unrelated"], firstResult, secondResult])
  }
}

@Test func anthropicToolResultsMustCompleteInFollowingUserTurn() throws {
  let calls: [[String: Any]] = ["call_1", "call_2"].map {
    ["type": "tool_use", "id": $0, "name": "lookup_code", "input": [:] as [String: Any]]
  }
  let results: [[String: Any]] = ["call_1", "call_2"].map {
    ["type": "tool_result", "tool_use_id": $0, "content": "blue"]
  }
  let prefix: [[String: Any]] = [["role": "user", "content": "lookup"],
    ["role": "assistant", "content": calls]]
  func parse(_ messages: [[String: Any]]) throws -> PublicCall {
    try PublicProtocol.parse(body(["model": "fixture", "max_tokens": 8,
      "messages": messages]), dialect: .anthropic)
  }
  _ = try parse(prefix + [["role": "user", "content": [
    ["type": "text", "text": "context"], results[0], results[1],
    ["type": "text", "text": "continue"]]]])
  #expect(throws: MoxError.self) {
    try parse(prefix + [["role": "user", "content": "unrelated"],
      ["role": "user", "content": results]])
  }
  #expect(throws: MoxError.self) {
    try parse(prefix + [["role": "user", "content": [results[0]]],
      ["role": "user", "content": [results[1]]]])
  }
}

@Test func anthropicErrorToolResultPreservesOrderAndFlag() throws {
  let value: [String: Any] = ["model": "fixture", "max_tokens": 16, "messages": [
    ["role": "user", "content": "lookup"],
    ["role": "assistant", "content": [["type": "text", "text": "before"],
      ["type": "tool_use", "id": "call_1", "name": "lookup_code", "input": ["code": "MOX-7"]],
      ["type": "text", "text": "after"]]],
    ["role": "user", "content": [["type": "text", "text": "context"],
      ["type": "tool_result", "tool_use_id": "call_1", "content": "unknown code", "is_error": true],
      ["type": "text", "text": "please recover"]]]]]
  let parsed = try PublicProtocol.parse(body(value), dialect: .anthropic)
  #expect(parsed.request.messages[1].content.count == 3)
  #expect(parsed.request.messages[2].content.count == 3)
  guard case .toolResult(let id, let text, let isError) = parsed.request.messages[2].content[1] else {
    Issue.record("Expected tool result in the original position")
    return
  }
  #expect(id == "call_1")
  #expect(text == "unknown code")
  #expect(isError)
}

@Test func publicResponseHasProtocolSpecificTerminalEvents() throws {
  let request = try GenerationRequest(messages: [.init(role: .user, text: "hi")], sampling: Sampling(maxTokens: 8))
  let usage = Usage(promptTokens: 4, outputTokens: 2, prefillSeconds: 0, decodeSeconds: 0)
  let open = PublicCall(dialect: .openAI, model: "fixture", request: request, stream: true, includeUsage: true)
  var openResponse = PublicResponse(call: open)
  let events: [GenerationPayload] = [.promptTokens(4), .contentDelta("Hi"), .usage(usage), .finished(.stop)]
  let openBytes = try events.enumerated().flatMap { index, payload in
    try openResponse.accept(.init(requestID: request.id, sequence: index, payload: payload))
  }.reduce(into: Data()) { $0.append($1) }
  let openText = String(decoding: openBytes, as: UTF8.self)
  #expect(openText.contains("\"prompt_tokens\":4"))
  #expect(openText.hasSuffix("data: [DONE]\n\n"))
  let anthropic = PublicCall(dialect: .anthropic, model: "fixture", request: request, stream: true, includeUsage: true)
  var anthropicResponse = PublicResponse(call: anthropic)
  let anthropicBytes = try events.enumerated().flatMap { index, payload in
    try anthropicResponse.accept(.init(requestID: request.id, sequence: index, payload: payload))
  }.reduce(into: Data()) { $0.append($1) }
  let anthropicText = String(decoding: anthropicBytes, as: UTF8.self)
  #expect(anthropicText.contains("event: message_start"))
  #expect(anthropicText.contains("event: message_stop"))
  #expect(!anthropicText.contains("[DONE]"))
}

@Test func publicToolCallsKeepOrderAndStableIdentifiers() throws {
  let request = try GenerationRequest(messages: [.init(role: .user, text: "two calls")],
    sampling: Sampling(maxTokens: 16))
  let usage = Usage(promptTokens: 7, outputTokens: 8, prefillSeconds: 0, decodeSeconds: 0)
  let call = PublicCall(dialect: .anthropic, model: "fixture", request: request,
    stream: false, includeUsage: true)
  var response = PublicResponse(call: call)
  let payloads: [GenerationPayload] = [
    .promptTokens(7), .contentDelta("before"),
    .toolCall(id: "call_first", name: "lookup_code", arguments: "{\"code\":\"MOX-7\"}"),
    .contentDelta("between"),
    .toolCall(id: "call_second", name: "lookup_code", arguments: "{\"code\":\"MOX-8\"}"),
    .usage(usage), .finished(.toolCalls),
  ]
  for (index, payload) in payloads.enumerated() {
    _ = try response.accept(.init(requestID: request.id, sequence: index, payload: payload))
  }
  let object = try #require(JSONSerialization.jsonObject(with: response.complete()) as? [String: Any])
  let blocks = try #require(object["content"] as? [[String: Any]])
  #expect(blocks.compactMap { $0["type"] as? String } == ["text", "tool_use", "text", "tool_use"])
  #expect(blocks[1]["id"] as? String == "call_first")
  #expect(blocks[3]["id"] as? String == "call_second")
}

@Test func publicStreamFailureNeverAddsSuccessTerminal() throws {
  let request = try GenerationRequest(messages: [.init(role: .user, text: "hi")],
    sampling: Sampling(maxTokens: 8))
  for dialect in [PublicDialect.openAI, .anthropic] {
    var response = PublicResponse(call: PublicCall(dialect: dialect, model: "fixture",
      request: request, stream: true, includeUsage: true))
    _ = try response.accept(.init(requestID: request.id, sequence: 0, payload: .promptTokens(4)))
    _ = try response.accept(.init(requestID: request.id, sequence: 1, payload: .contentDelta("partial")))
    let failure = MoxError(.generationFailed, "Generation failed.")
    #expect(throws: MoxError.self) {
      try response.accept(.init(requestID: request.id, sequence: 2, payload: .failed(failure)))
    }
    let error = String(decoding: PublicResponse.streamError(failure, dialect: dialect), as: UTF8.self)
    #expect(error.contains("Generation failed."))
    #expect(!error.contains("[DONE]"))
    #expect(!error.contains("message_stop"))
  }
}

@Test func toolSchemaObjectAndNameValidationRejectsMalformedDefinitions() throws {
  for schema in ["[]", "{\"type\":\"array\"}", "{}", "invalid"] {
    #expect(throws: MoxError.self) { try ToolDefinition(name: "fixture", parametersJSON: schema) }
  }
  #expect(throws: MoxError.self) { try ToolDefinition(name: "", parametersJSON: "{\"type\":\"object\"}") }
  #expect(HTTPFailureStatus.status(MoxError(.storageFailed, "fixture")) == .internalServerError)
}
