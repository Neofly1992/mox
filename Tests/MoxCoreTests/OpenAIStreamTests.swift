import Foundation
import Testing
@testable import MoxShared

/// Wire-shape tests for the OpenAI streaming contract. v0.7 wires the daemon
/// to honour `stream_options.include_usage`; lock the chunk shape and the
/// usage-chunk placement so the GUI client and CLI agree with the daemon.
@Suite("OpenAI streaming wire shape")
struct OpenAIStreamTests {

    @Test("Request decodes stream_options.include_usage")
    func decodesIncludeUsage() throws {
        let json = #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{"include_usage":true}}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.stream == true)
        #expect(req.streamOptions?.includeUsage == true)
    }

    @Test("Request decodes without stream_options (nil)")
    func decodesMissingStreamOptions() throws {
        let json = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.streamOptions == nil)
    }

    @Test("Chunk with nil usage is emitted when client did not opt in")
    func chunkOmitsUsageByDefault() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-x",
            object: "chat.completion.chunk",
            created: 1,
            model: "m",
            choices: [
                ChatCompletionChunk.Choice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(role: nil, content: "hi"),
                    finishReason: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(chunk)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("\"usage\""))
    }

    @Test("Chunk with usage populates snake_case fields")
    func chunkEncodesUsage() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-x",
            object: "chat.completion.chunk",
            created: 1,
            model: "m",
            choices: [
                ChatCompletionChunk.Choice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(role: nil, content: ""),
                    finishReason: nil
                )
            ],
            usage: ChatCompletionChunk.Usage(
                promptTokens: 12,
                completionTokens: 5,
                totalTokens: 17
            )
        )
        let data = try JSONEncoder().encode(chunk)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"usage\""))
        #expect(json.contains("\"prompt_tokens\":12"))
        #expect(json.contains("\"completion_tokens\":5"))
        #expect(json.contains("\"total_tokens\":17"))
    }

    @Test("Usage-only chunk still has empty choices (OpenAI convention)")
    func usageChunkHasEmptyChoices() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-x",
            object: "chat.completion.chunk",
            created: 1,
            model: "m",
            choices: [
                ChatCompletionChunk.Choice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(role: nil, content: ""),
                    finishReason: nil
                )
            ],
            usage: ChatCompletionChunk.Usage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        )
        // Round-trip via JSONDecoder to lock the field ordering / shape.
        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        #expect(decoded.usage?.promptTokens == 1)
        #expect(decoded.choices.count == 1)
        #expect(decoded.choices[0].delta.content == "")
    }
}