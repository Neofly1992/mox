import Foundation
import MLX
import MLXNN
import Testing
@testable import MoxConvertCore

/// MoxQuant is the v0.9 `mox convert` engine. It depends on a real
/// MLX model + tokenizer to run end-to-end, which we don't have in
/// CI; these tests pin the type-level contract and argument parsing
/// so a future `mox convert` CLI can rely on it without surprises.
@Suite("MoxQuant")
struct MoxQuantTests {

    @Test("QuantizationOptions defaults match MLXNN.quantize defaults")
    func defaultsMatchMLX() {
        let options = QuantizationOptions(outputDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(options.bits == 4)
        #expect(options.groupSize == 64)
        // The default mode on `MLXNN.quantize` is `.affine`; this is a
        // behavioural contract — if upstream ever changes the default,
        // mox must follow.
        let mlxDefault = MLX.QuantizationMode.affine
        #expect(options.mode == mlxDefault)
    }

    @Test("QuantizationOptions custom values round-trip")
    func customValues() {
        let url = URL(fileURLWithPath: "/tmp/mox")
        let options = QuantizationOptions(
            bits: 8,
            groupSize: 128,
            mode: .affine,
            outputDirectory: url
        )
        #expect(options.bits == 8)
        #expect(options.groupSize == 128)
        #expect(options.mode == .affine)
        #expect(options.outputDirectory == url)
    }

    @Test("MoxQuantError error description names the offending mode")
    func errorDescription() {
        let err = MoxQuantError.unsupportedQuantizationMode("fp32")
        #expect(err.errorDescription?.contains("fp32") == true)
        #expect(err.errorDescription?.contains("affine") == true)
    }
}
