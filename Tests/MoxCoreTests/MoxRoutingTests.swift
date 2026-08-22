import Foundation
import Testing
@testable import MoxCore
@testable import MoxConvertCore
@testable import MoxShared

/// Tests for the v0.5 pull smart-routing helper. `deriveManifestFields`
/// is a pure function so the routing decisions can be exercised without
/// standing up a real model directory.
@Suite("Mox pull routing")
struct MoxRoutingTests {

    @Test("MLX-quantized probe + huggingface source records upstream provenance")
    func mlxQuantizedFromHF() {
        let (sf, q) = deriveManifestFields(
            probe: .mlxQuantized,
            source: .huggingface
        )
        #expect(sf == "mlx-upstream-quantized")
        #expect(q == nil)
    }

    @Test("MLX-quantized probe + modelscope source records upstream provenance")
    func mlxQuantizedFromModelScope() {
        let (sf, q) = deriveManifestFields(
            probe: .mlxQuantized,
            source: .modelscope
        )
        #expect(sf == "mlx-upstream-quantized")
        #expect(q == nil)
    }

    @Test("bf16 probe tags format as hf-bfloat16")
    func bf16FromHF() {
        let (sf, q) = deriveManifestFields(
            probe: .hfPrecision(dtype: "bfloat16"),
            source: .huggingface
        )
        #expect(sf == "huggingface-bfloat16")
        #expect(q == nil)
    }

    @Test("bf16 probe from modelscope tags format as modelscope-bfloat16")
    func bf16FromMS() {
        let (sf, q) = deriveManifestFields(
            probe: .hfPrecision(dtype: "bfloat16"),
            source: .modelscope
        )
        #expect(sf == "modelscope-bfloat16")
        #expect(q == nil)
    }

    @Test("fp16 / fp32 paths tag correctly")
    func fp16FromHF() {
        let (sf, _) = deriveManifestFields(
            probe: .hfPrecision(dtype: "float16"),
            source: .huggingface
        )
        #expect(sf == "huggingface-float16")
    }

    @Test("unknown probe carries the reason in the source format")
    func unknownReasonPropagated() {
        let (sf, q) = deriveManifestFields(
            probe: .unknown(reason: "missing model_type"),
            source: .huggingface
        )
        #expect(sf.contains("unknown"))
        #expect(sf.contains("missing model_type"))
        #expect(q == nil)
    }

    @Test("MoxConverter.inspect on MLX-quantized config returns mlxQuantized")
    func inspectRoundTripMLX() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config: [String: Any] = [
            "model_type": "qwen2",
            "quantization_config": ["group_size": 64, "bits": 4]
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: dir.appendingPathComponent("config.json"))

        let probe = try MoxConverter().inspect(at: dir)
        let (sf, q) = deriveManifestFields(probe: probe, source: .huggingface)
        #expect(sf == "mlx-upstream-quantized")
        #expect(q == nil)
    }

    @Test("MoxConverter.inspect on bf16 config returns hfPrecision → bf16 manifest")
    func inspectRoundTripBF16() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config: [String: Any] = [
            "model_type": "qwen2",
            "torch_dtype": "bfloat16"
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: dir.appendingPathComponent("config.json"))

        let probe = try MoxConverter().inspect(at: dir)
        let (sf, q) = deriveManifestFields(probe: probe, source: .modelscope)
        #expect(sf == "modelscope-bfloat16")
        #expect(q == nil)
    }
}
