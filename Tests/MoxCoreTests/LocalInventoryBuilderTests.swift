import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

@Suite("LocalInventoryBuilder")
struct LocalInventoryBuilderTests {

    @Test("Empty directory produces empty inventory")
    func emptyDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-inv-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inventory = try LocalInventoryBuilder.walk(directory: dir)
        #expect(inventory.isEmpty)
        #expect((try? LocalInventoryBuilder.totalBytes(directory: dir)) == 0)
    }
    }

    @Test("Walks files recursively and skips manifest")
    func recursiveWalk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-inv-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = root.appendingPathComponent("config.json")
        let weightsDir = root.appendingPathComponent("weights")
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        let weights = weightsDir.appendingPathComponent("model.safetensors")
        try Data(repeating: 0, count: 100).write(to: config)
        try Data(repeating: 0, count: 1_000).write(to: weights)

        // Manifest must be ignored — bookkeeping, not a model file.
        let manifest: [String: Any] = ["id": "x", "source": "huggingface"]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: root.appendingPathComponent("mox.json"))

        let inv = try LocalInventoryBuilder.walk(directory: root)
        #expect(inv.count == 2)
        #expect(inv["config.json"]?.sizeBytes == 100)
        #expect(inv["model.safetensors"]?.sizeBytes == 1_000)
        #expect(inv["mox.json"] == nil)
        #expect((try? LocalInventoryBuilder.totalBytes(directory: root)) == 1_100)
}

