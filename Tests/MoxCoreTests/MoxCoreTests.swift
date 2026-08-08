import XCTest
@testable import MoxCore
@testable import MoxShared

final class MoxCoreTests: XCTestCase {
    func testConfigManager() throws {
        let config = AppConfig()
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.defaultSource, .huggingface)
        XCTAssertEqual(config.server.port, 8080)
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
}
