import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// Migrated from XCTestCase → @Test (Swift Testing) in v0.4 to remove the
/// XCTest framework dependency. CommandLineTools SDK does not ship XCTest,
/// and depending on the full Xcode toolchain just for unit tests is heavy.

@Suite("MoxCore")
struct MoxCoreTests {

    @Test("AppConfig defaults match v0.3 baseline")
    func configManager() {
        let config = AppConfig()
        #expect(config.version == 1)
        #expect(config.defaultSource == .huggingface)
        #expect(config.server.port == 11555)
    }

    @Test("ModelInfo round-trips id and human-readable size")
    func modelInfo() {
        let info = ModelInfo(
            id: "test-model",
            name: "Test Model",
            source: .huggingface,
            path: "/tmp/test",
            size: 1024 * 1024 * 100,
            lastUsed: nil
        )

        #expect(info.id == "test-model")
        let s = info.sizeDescription
        // ByteCountFormatter may emit U+2006 SIX-PER-EM SPACE on newer macOS;
        // compare after normalising common Unicode whitespace to a single space.
        let normalized = s.unicodeScalars.map { scalar -> Character in
            CharacterSet.whitespaces.contains(scalar) ? " " : Character(scalar)
        }.reduce(into: "") { $0.append($1) }
        #expect(normalized == "100 MB")
    }

    @Test("MemoryGuard reports positive totals and non-negative available")
    func memoryGuard() {
        let memoryGuard = MemoryGuard(reservePercent: 0.1)
        let status = memoryGuard.getMemoryStatus()

        #expect(status.totalGB > 0)
        #expect(status.availableGB >= 0)
    }

    @Test("ModelRunner.shared lists nothing on a fresh process")
    func runnerCompilesAndTypes() async {
        let config = AppConfig()
        #expect(config.defaults.maxTokens > 0)

        let messages = [
            ChatMessage(role: "system", content: "You are mox."),
            ChatMessage(role: "user", content: "Hello!"),
        ]
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")

        let ids = await ModelRunner.shared.listLoadedModels()
        #expect(ids.isEmpty)
    }

    /// The CLI's `mox ask` (non-streaming) emits a single
    /// `ChatCompletionResponse` document. Lock the JSON shape so the daemon's
    /// `/v1/chat/completions` endpoint and the GUI's `HTTPAPIClient` agree
    /// on field names.
    @Test("ChatCompletionResponse JSON shape matches OpenAI")
    func chatCompletionResponseShape() throws {
        let response = ChatCompletionResponse(
            id: "chatcmpl-abc",
            created: 1_700_000_000,
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            choices: [
                ChatCompletionResponse.Choice(
                    index: 0,
                    message: ChatCompletionResponse.AssistantMessage(content: "hi"),
                    finishReason: "stop"
                )
            ],
            usage: ChatCompletionResponse.Usage(
                promptTokens: 1,
                completionTokens: 1,
                totalTokens: 2
            )
        )
        let data = try JSONEncoder().encode(response)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"object\":\"chat.completion\""))
        #expect(json.contains("\"model\":"))
        #expect(json.contains("Qwen2.5-0.5B-Instruct"))
        #expect(json.contains("\"finish_reason\":\"stop\""))
        #expect(json.contains("\"prompt_tokens\":1"))
        #expect(json.contains("\"completion_tokens\":1"))
        #expect(json.contains("\"total_tokens\":2"))
        #expect(json.contains("\"content\":\"hi\""))
    }

    /// The CLI's `mox ask --stream` emits one `ChatCompletionChunk` per line.
    /// Lock the shape so the GUI's `ProcessAPIClient` and the future daemon
    /// SSE endpoint decode it identically.
    @Test("ChatCompletionChunk JSON shape matches OpenAI streaming")
    func chatCompletionChunkShape() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-xyz",
            object: "chat.completion.chunk",
            created: 1_700_000_000,
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            choices: [
                ChatCompletionChunk.Choice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(role: "assistant", content: "hi"),
                    finishReason: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(chunk)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"object\":\"chat.completion.chunk\""))
        #expect(json.contains("\"role\":\"assistant\""))
        #expect(json.contains("\"content\":\"hi\""))
        // Swift's default JSONEncoder omits nil Optionals — `finish_reason`
        // is dropped from the wire payload when null. The CLI's streaming
        // output therefore omits the key entirely for content chunks; the
        // terminal "stop" chunk emits it.
        #expect(!json.contains("finish_reason"))
    }
}
