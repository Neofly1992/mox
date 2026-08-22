import Foundation
import Testing
@testable import MoxShared

/// Wire-shape tests for the legacy `/v1/completions` endpoint. v0.7 ships
/// text-only; `echo`, `logprobs`, `best_of`, `suffix` are decoded so a
/// malformed request becomes a structured 400 instead of a parse crash.
@Suite("/v1/completions wire shape")
struct CompletionsTests {

    @Test("Request decodes required fields")
    func decodesRequired() throws {
        let json = #"{"model":"m","prompt":"hi"}"#
        let req = try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
        #expect(req.model == "m")
        #expect(req.prompt == "hi")
        #expect(req.stream == nil)
        #expect(req.temperature == nil)
    }

    @Test("Request decodes optional fields including stream_options")
    func decodesOptional() throws {
        let json = #"{"model":"m","prompt":"hi","max_tokens":32,"temperature":0.3,"top_p":0.9,"stream":true,"stream_options":{"include_usage":true},"echo":false}"#
        let req = try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
        #expect(req.maxTokens == 32)
        #expect(req.temperature == 0.3)
        #expect(req.topP == 0.9)
        #expect(req.stream == true)
        #expect(req.streamOptions?.includeUsage == true)
        #expect(req.echo == false)
    }

    @Test("Response serialises object: text_completion")
    func responseSerialises() throws {
        let resp = CompletionResponse(
            id: "cmpl-x",
            created: 1,
            model: "m",
            choices: [CompletionResponse.Choice(index: 0, text: "hi", finishReason: "stop")],
            usage: ChatCompletionResponse.Usage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        )
        let data = try JSONEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"object\":\"text_completion\""))
        #expect(json.contains("\"text\":\"hi\""))
        #expect(json.contains("\"finish_reason\":\"stop\""))
        #expect(json.contains("\"prompt_tokens\":1"))
    }

    @Test("Chunk serialises object: text_completion with optional usage")
    func chunkSerialises() throws {
        let chunk = CompletionChunk(
            id: "cmpl-x",
            created: 1,
            model: "m",
            choices: [CompletionChunk.Choice(index: 0, text: "hi", finishReason: nil)]
        )
        let data = try JSONEncoder().encode(chunk)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"object\":\"text_completion\""))
        #expect(!json.contains("\"usage\""))
    }
}