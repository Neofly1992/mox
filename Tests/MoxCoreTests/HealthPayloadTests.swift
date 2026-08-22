import Foundation
import Testing
@testable import MoxShared

/// Wire-shape tests for `GET /health`. v0.7+ returns a rich body so coding
/// agents can introspect the runtime without round-tripping `/v1/models`.
/// Lock the field names so the GUI client can decode them.
@Suite("Health payload wire shape")
struct HealthPayloadTests {

    @Test("Empty models array still decodes cleanly")
    func emptyModelsRoundTrip() throws {
        let payload = HealthPayload(
            status: "ok",
            moxVersion: "0.7.0",
            serverVersion: "0.7.0",
            models: [],
            capabilities: .v07,
            samplerDefaults: SamplerDefaults(),
            runtime: HealthPayload.Runtime(host: "127.0.0.1", port: 11555, maxBodyBytes: 16 * 1024 * 1024)
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"mox_version\":\"0.7.0\""))
        #expect(json.contains("\"server_version\":\"0.7.0\""))
        #expect(json.contains("\"openai_chat_completions\":true"))
        #expect(json.contains("\"openai_stream\":true"))
        #expect(json.contains("\"openai_usage\":true"))
        #expect(json.contains("\"anthropic_messages\":true"))
        // v0.7 had tool_calls/embeddings false; v0.8 flips tool_calls true.
        #expect(json.contains("\"tool_calls\":true"))
        #expect(json.contains("\"embeddings\":false"))
        let decoded = try JSONDecoder().decode(HealthPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("Model capability with tool-call support serialises correctly")
    func modelCapabilityWithTools() throws {
        let cap = HealthPayload.ModelCapability(
            id: "Qwen/Qwen2.5-7B-Instruct",
            family: "qwen2",
            loaded: true,
            supportsToolCalls: true,
            contextWindow: 32768,
            warmupTokens: 16
        )
        let data = try JSONEncoder().encode(cap)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"family\":\"qwen2\""))
    }

    @Test("Capabilities.v08 advertises tools + completions but no embeddings")
    func v08CapabilityDefaults() {
        #expect(HealthPayload.Capabilities.v07.openaiChatCompletions)
        #expect(HealthPayload.Capabilities.v07.openaiStream)
        #expect(HealthPayload.Capabilities.v07.openaiUsage)
        #expect(HealthPayload.Capabilities.v07.openaiCompletions)
        #expect(HealthPayload.Capabilities.v07.anthropicMessages)
        #expect(HealthPayload.Capabilities.v07.anthropicStream)
        #expect(HealthPayload.Capabilities.v07.toolCalls)
        #expect(!HealthPayload.Capabilities.v07.embeddings)
    }

}