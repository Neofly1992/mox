import XCTest
@testable import MoxCore

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
        XCTAssertEqual(info.sizeDescription, "100 MB")
    }
    
    func testMemoryGuard() throws {
        let memoryGuard = MemoryGuard(reservePercent: 0.1)
        let status = memoryGuard.getMemoryStatus()
        
        XCTAssertGreaterThan(status.totalGB, 0)
        XCTAssertGreaterThanOrEqual(status.availableGB, 0)
    }
}
