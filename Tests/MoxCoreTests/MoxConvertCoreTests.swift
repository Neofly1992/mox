import Foundation
import Testing
@testable import MoxConvertCore
@testable import MoxShared

/// Tests for `MoxConverter.inspect` — the routing decision `mox pull`
/// uses to decide whether a pulled model is ready-to-use or needs
/// conversion. Conversion itself is deferred until mlx-swift exposes a
/// public Module→safetensors writer; see MoxConvertCore.swift header.
@Suite("MoxConvertCore routing probe")
struct MoxConvertCoreTests {

    private func makeTmpDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-probe-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ dict: [String: Any], to dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: dir.appendingPathComponent("config.json"))
    }

    @Test("directory without config.json reports unknown")
    func missingConfig() throws {
        let dir = try makeTmpDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = try MoxConverter().inspect(at: dir)
        if case .unknown(let reason) = probe {
            #expect(reason.contains("config.json missing"))
        } else {
            Issue.record("expected .unknown, got \(probe)")
        }
    }

    @Test("config with quantization_config reports mlxQuantized")
    func mlxQuantizedBranch() throws {
        let dir = try makeTmpDir("mlx")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig([
            "architectures": ["Qwen2ForCausalLM"],
            "model_type": "qwen2",
            "torch_dtype": "bfloat16",
            "quantization_config": ["group_size": 64, "bits": 4],
        ], to: dir)
        let probe = try MoxConverter().inspect(at: dir)
        #expect(probe == .mlxQuantized)
    }

    @Test("config without quantization_config reports hfPrecision")
    func hfPrecisionBranch() throws {
        let dir = try makeTmpDir("hf")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig([
            "architectures": ["Qwen2ForCausalLM"],
            "model_type": "qwen2",
            "torch_dtype": "bfloat16",
        ], to: dir)
        let probe = try MoxConverter().inspect(at: dir)
        if case .hfPrecision(let dtype) = probe {
            #expect(dtype == "bfloat16")
        } else {
            Issue.record("expected .hfPrecision(bfloat16), got \(probe)")
        }
    }

    @Test("config missing model_type reports unknown")
    func unknownBranch() throws {
        let dir = try makeTmpDir("unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig([
            "architectures": ["UnknownForCausalLM"],
        ], to: dir)
        let probe = try MoxConverter().inspect(at: dir)
        if case .unknown(let reason) = probe {
            #expect(reason.contains("model_type"))
        } else {
            Issue.record("expected .unknown, got \(probe)")
        }
    }

    @Test("config with quantization but missing model_type still reports mlxQuantized")
    func mlxQuantizedBeatsUnknown() throws {
        let dir = try makeTmpDir("mlx-beats-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig([
            "architectures": ["X"],
            "quantization_config": ["bits": 4],
        ], to: dir)
        let probe = try MoxConverter().inspect(at: dir)
        #expect(probe == .mlxQuantized)
    }

    @Test("missing torch_dtype reports unknown rather than guessing bf16")
    func missingDtypeReportsUnknown() throws {
        let dir = try makeTmpDir("dtype-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig([
            "model_type": "llama",
        ], to: dir)
        let probe = try MoxConverter().inspect(at: dir)
        if case .unknown(let reason) = probe {
            #expect(reason.contains("torch_dtype"))
        } else {
            Issue.record("expected .unknown, got \(probe)")
        }
    }
}