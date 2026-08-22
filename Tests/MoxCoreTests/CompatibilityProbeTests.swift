import Foundation
import Testing
@testable import MoxConvertCore
@testable import MoxShared

/// Probe contract: classify a model directory into one of five tiers
/// without making any network calls. The probe's failure mode is
/// `.unknown`, never silent downgrade.
@Suite("CompatibilityProbe")
struct CompatibilityProbeTests {

    private func writeConfig(_ json: String, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))
    }

    @Test("Missing config.json yields unknown")
    func missingConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .unknown)
        #expect(verdict.modelType == nil)
    }

    @Test("mlxBuiltin family + quantization_config = mlxBuiltin")
    func mlxBuiltinQuantized() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-qwen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig("""
        {"model_type":"qwen2","quantization_config":{"group_size":64,"bits":4}}
        """, to: dir)
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .mlxBuiltin)
        #expect(verdict.modelType == "qwen2")
    }

    @Test("mlxBuiltin family without quantization_config = communityUnverified")
    func mlxBuiltinBare() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-qwenbare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"model_type":"qwen2"}"#, to: dir)
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .communityUnverified)
        #expect(verdict.modelType == "qwen2")
    }

    @Test("arOnly family yields arOnly")
    func arOnlyFamily() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-mixtral-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"model_type":"mixtral"}"#, to: dir)
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .arOnly)
    }

    @Test("Unknown model_type yields incompatible, never guess")
    func unknownFamily() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-opt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"model_type":"opt"}"#, to: dir)
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .incompatible)
        #expect(verdict.modelType == "opt")
    }

    @Test("Missing model_type yields unknown")
    func missingModelType() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"architectures":["LLaMA"]}"#, to: dir)
        let verdict = try CompatibilityProbe.probe(at: dir)
        #expect(verdict.tier == .unknown)
        #expect(verdict.modelType == nil)
    }

    @Test("Compare returns match when persisted tier equals fresh probe")
    func compareMatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-cmp-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"model_type":"qwen2","quantization_config":{"bits":4}}"#, to: dir)
        let verdict = CompatibilityProbe.compare(directory: dir, manifestTier: .mlxBuiltin)
        #expect(verdict == .match(.mlxBuiltin))
    }

    @Test("Compare returns mismatch when manifest was tampered with")
    func compareMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-cp-cmp-mis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(#"{"model_type":"opt"}"#, to: dir)
        let verdict = CompatibilityProbe.compare(directory: dir, manifestTier: .mlxBuiltin)
        #expect(verdict == .mismatch(persisted: .mlxBuiltin, fresh: .incompatible))
    }

    @Test("Manifest round-trips compatibility through Codable")
    func manifestRoundTrip() throws {
        let manifest = ModelManifest(
            id: "test/model",
            source: .huggingface,
            originalId: "test/model",
            compatibility: ModelCompatibility(
                tier: .mlxBuiltin,
                reason: "matched",
                modelType: "qwen2"
            )
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded.compatibility?.tier == .mlxBuiltin)
        #expect(decoded.compatibility?.modelType == "qwen2")
        #expect(decoded.compatibility?.reason == "matched")
    }
}