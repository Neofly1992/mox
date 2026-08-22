import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// Tests for the Anthropic Messages API wire-format compatibility. The
/// translation logic (request decode → ChatMessage[] → response encode)
/// is pure Swift and can be exercised without running the model.
@Suite("Anthropic wire format")
struct AnthropicTests {

    @Test("AnthropicMessagesRequest decodes text-only messages")
    func decodeTextOnly() throws {
        let json = """
        {
          "model": "mlx-community/Qwen3-4B-4bit",
          "max_tokens": 64,
          "messages": [
            {"role": "user", "content": "Hello"}
          ]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: json)
        #expect(req.model == "mlx-community/Qwen3-4B-4bit")
        #expect(req.maxTokens == 64)
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == "user")
        #expect(req.messages[0].content.flattenedText == "Hello")
        #expect(req.system == nil)
        #expect(req.stream == nil)
    }

    @Test("AnthropicMessagesRequest decodes system + content block arrays")
    func decodeSystemAndBlocks() throws {
        let json = """
        {
          "model": "mlx-community/Qwen3-4B-4bit",
          "max_tokens": 32,
          "system": "You are concise.",
          "messages": [
            {"role": "user", "content": [
              {"type": "text", "text": "Hi "},
              {"type": "text", "text": "there"}
            ]}
          ]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: json)
        #expect(req.system?.flattenedText == "You are concise.")
        #expect(req.messages[0].content.flattenedText == "Hi \nthere")
    }

    @Test("AnthropicMessagesResponse round-trips through JSONEncoder")
    func responseRoundTrip() throws {
        let resp = AnthropicMessagesResponse(
            id: "msg_test",
            content: [.text("Hello world")],
            model: "test-model",
            stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 4, outputTokens: 2)
        )
        let data = try JSONEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"type\":\"message\""))
        #expect(json.contains("\"role\":\"assistant\""))
        #expect(json.contains("\"id\":\"msg_test\""))
        #expect(json.contains("\"stop_reason\":\"end_turn\""))
        #expect(json.contains("\"input_tokens\":4"))
        #expect(json.contains("\"output_tokens\":2"))
        #expect(json.contains("\"text\":\"Hello world\""))

        let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        #expect(decoded.id == "msg_test")
        #expect(decoded.content.first?.flattenedText == "Hello world")
        #expect(decoded.usage.inputTokens == 4)
        #expect(decoded.usage.outputTokens == 2)
    }

    @Test("AnthropicMessagesResponse serialises content blocks correctly")
    func responseContentBlocks() throws {
        let resp = AnthropicMessagesResponse(
            id: "msg_x",
            content: [.text("hello")],
            model: "m",
            stopReason: nil,
            usage: AnthropicUsage(inputTokens: 1, outputTokens: 1)
        )
        let data = try JSONEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8) ?? ""
        // structural pieces instead of exact key order, since AnyCodable
        // re-encoding doesn't preserve CodingKey declaration order.
        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"text\":\"hello\""))
        #expect(json.contains("\"content\":[{"))
    }
    @Test("AnthropicErrorResponse serialises in the documented shape")
    func errorResponseShape() throws {
        let resp = AnthropicErrorResponse(error: .init(
            type: "invalid_request_error",
            message: "tools are not supported in this Mox build (v0.4.1)"
        ))
        let data = try JSONEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"type\":\"error\""))
        #expect(json.contains("\"type\":\"invalid_request_error\""))
        #expect(json.contains("tools are not supported"))
    }

    @Test("AnthropicTool decode succeeds but downstream rejects with 400")
    func toolsDecode() throws {
        let json = """
        {
          "model": "m",
          "max_tokens": 8,
          "messages": [{"role": "user", "content": "hi"}],
          "tools": [
            {"name": "get_weather", "description": "x",
             "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}}}
          ]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: json)
        #expect(req.tools?.count == 1)
        #expect(req.tools?[0].name == "get_weather")
        // The handler's contract is to reject when tools.isEmpty == false.
        // We don't run the handler here — the model layer would need to be
        // mocked — but the data path is exercised above.
    }

    @Test("content blocks of unknown type are preserved verbatim via .other")
    func unknownContentBlockPreserved() throws {
        let json = """
        {
          "model": "m",
          "max_tokens": 8,
          "messages": [{"role": "user", "content": [
            {"type": "text", "text": "see image:"},
            {"type": "image", "source": {"type": "base64", "data": "abc"}}
          ]}]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: json)
        // flattenedText only carries the text block; the image block is
        // dropped from the forwarded prompt but the request itself parsed.
        #expect(req.messages[0].content.flattenedText == "see image:")
        if case .blocks(let blocks) = req.messages[0].content {
            #expect(blocks.count == 2)
            if case .other(let type, _) = blocks[1] {
                #expect(type == "image")
            } else {
                Issue.record("expected .other for image block, got text")
            }
        } else {
            Issue.record("expected .blocks variant")
        }
    }

    @Test("AnyCodable round-trips all primitive types")
    func anyCodablePrimitives() throws {
        let cases: [AnyCodable] = [
            .null, .bool(true), .int(42), .double(3.14),
            .string("hi"), .array([.int(1), .string("x")]),
            .object(["k": .bool(false)])
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(AnyCodable.self, from: data)
            // Encode + decode round-trip preserves structural equality.
            let data2 = try JSONEncoder().encode(back)
            #expect(data == data2)
        }
    }
}
