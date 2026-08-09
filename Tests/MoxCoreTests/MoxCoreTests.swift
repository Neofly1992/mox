import XCTest
@testable import MoxCore
@testable import MoxShared

final class MoxCoreTests: XCTestCase {
    func testConfigManager() throws {
        let config = AppConfig()
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.defaultSource, .huggingface)
        XCTAssertEqual(config.server.port, 11555)
    }
    
    func testModelInfo() throws {
        let info = ModelInfo(
            id: "test-model",
            name: "Test Model",
            source: .huggingface,
            path: "/tmp/test",
            size: 1024 * 1024 * 100,
            lastUsed: nil
        )
        
        XCTAssertEqual(info.id, "test-model")
        let s = info.sizeDescription
        // ByteCountFormatter may emit U+2006 SIX-PER-EM SPACE on newer macOS;
        // compare after normalising common Unicode whitespace to a single space.
        let normalized = s.unicodeScalars.map { scalar -> Character in
            CharacterSet.whitespaces.contains(scalar) ? " " : Character(scalar)
        }.reduce(into: "") { $0.append($1) }
        XCTAssertEqual(normalized, "100 MB")
    }
    
    func testMemoryGuard() throws {
        let memoryGuard = MemoryGuard(reservePercent: 0.1)
        let status = memoryGuard.getMemoryStatus()
        
        XCTAssertGreaterThan(status.totalGB, 0)
        XCTAssertGreaterThanOrEqual(status.availableGB, 0)
    }

    func testRunnerCompilesAndTypes() async throws {
        let config = AppConfig()
        XCTAssertTrue(config.defaults.maxTokens > 0)

        let messages = [
            ChatMessage(role: "system", content: "You are mox."),
            ChatMessage(role: "user", content: "Hello!"),
        ]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")

        let ids = await ModelRunner.shared.listLoadedModels()
        XCTAssertTrue(ids.isEmpty)
    }

    /// The CLI's `mox ask` (non-streaming) emits a single
    /// `ChatCompletionResponse` document. Lock the JSON shape so the daemon's
    /// `/v1/chat/completions` endpoint and the GUI's `HTTPAPIClient` agree
    /// on field names.
    func testChatCompletionResponseShape() throws {
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
        XCTAssertTrue(json.contains("\"object\":\"chat.completion\""))
        XCTAssertTrue(json.contains("\"model\":"))
        XCTAssertTrue(json.contains("Qwen2.5-0.5B-Instruct"))
        XCTAssertTrue(json.contains("\"finish_reason\":\"stop\""))
        XCTAssertTrue(json.contains("\"prompt_tokens\":1"))
        XCTAssertTrue(json.contains("\"completion_tokens\":1"))
        XCTAssertTrue(json.contains("\"total_tokens\":2"))
        XCTAssertTrue(json.contains("\"content\":\"hi\""))
    }

    /// The CLI's `mox ask --stream` emits one `ChatCompletionChunk` per line.
    /// Lock the shape so the GUI's `ProcessAPIClient` and the future daemon
    /// SSE endpoint decode it identically.
    func testChatCompletionChunkShape() throws {
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
        XCTAssertTrue(json.contains("\"object\":\"chat.completion.chunk\""))
        XCTAssertTrue(json.contains("\"role\":\"assistant\""))
        XCTAssertTrue(json.contains("\"content\":\"hi\""))
        // Swift's default JSONEncoder omits nil Optionals — `finish_reason`
        // is dropped from the wire payload when null. The CLI's streaming
        // output therefore omits the key entirely for content chunks; the
        // terminal "stop" chunk emits it.
        XCTAssertFalse(json.contains("finish_reason"))
    }
}
