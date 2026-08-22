import Foundation
import Testing
@testable import MoxShared

/// Wire-shape tests for the v0.8 `/v1/embeddings` endpoint. v0.8 only
/// ships the request/response types and a structured 501; the actual
/// embedder actor is v0.9.
@Suite("/v1/embeddings wire shape")
struct EmbeddingTests {

    @Test("Decodes single-string input")
    func decodesSingleInput() throws {
        let json = #"{"model":"text-embed-1","input":"hello"}"#
        let req = try JSONDecoder().decode(EmbeddingRequest.self, from: Data(json.utf8))
        #expect(req.model == "text-embed-1")
        #expect(req.input == .single("hello"))
        #expect(req.input.count == 1)
    }

    @Test("Decodes array input")
    func decodesBatchInput() throws {
        let json = #"{"model":"text-embed-1","input":["hello","world"]}"#
        let req = try JSONDecoder().decode(EmbeddingRequest.self, from: Data(json.utf8))
        if case .batch(let arr) = req.input {
            #expect(arr == ["hello", "world"])
        } else {
            Issue.record("expected batch input")
        }
        #expect(req.input.count == 2)
    }

    @Test("Encoding round-trip preserves shape")
    func encodingRoundTrip() throws {
        let original = EmbeddingRequest(
            model: "m",
            input: .batch(["a", "b", "c"])
        )
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"input\":[\"a\",\"b\",\"c\"]"))
        let decoded = try JSONDecoder().decode(EmbeddingRequest.self, from: data)
        #expect(decoded.input == original.input)
    }

    @Test("EmbeddingResponse encodes list shape")
    func responseEncodes() throws {
        let resp = EmbeddingResponse(
            data: [
                EmbeddingEntry(embedding: [0.1, 0.2, 0.3], index: 0),
                EmbeddingEntry(embedding: [0.4, 0.5, 0.6], index: 1),
            ],
            model: "m",
            usage: EmbeddingUsage(promptTokens: 5, totalTokens: 5)
        )
        let data = try JSONEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"object\":\"list\""))
        #expect(json.contains("\"prompt_tokens\":5"))
    }

    @Test("501 error envelope has structured code")
    func notImplementedEnvelope() throws {
        let envelope = EmbeddingNotImplementedError(error: EmbeddingNotImplementedError.notImplemented)
        let data = try JSONEncoder().encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"code\":\"embeddings_not_implemented\""))
        #expect(json.contains("\"type\":\"server_error\""))
    }
}