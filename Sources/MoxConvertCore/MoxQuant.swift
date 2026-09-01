import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Quantize a HF bf16/fp16/fp32 model directory into the MLX safetensors
/// shape that mlx-swift-lm's `loadModelContainer` consumes natively.
///
/// Pipeline (DESIGN §15.2.1):
/// 1. `loadModelContainer(from:using:)` — already what `mox run` uses;
///    loads the original weights via the MLXLMCommon loader.
/// 2. `MLXNN.quantize(model:groupSize:bits:mode:filter:apply:)` —
///    in-place quantizes every leaf Linear / Embedding to the requested
///    bit width. The ModelContext is held in an actor; we run the
///    quantize inside `container.perform { context in ... }` so the
///    in-flight MLXArray stays inside its isolation domain.
/// 3. `model.parameters().flattened(prefix:)` returns `[String: MLXArray]`
///    in dotted notation (e.g. "model.layers.0.self_attn.q_proj.weight").
/// 4. `MLX.save(arrays:metadata:url:stream:)` writes the dict to a
///    `model.safetensors` sibling file plus an optional metadata JSON.
///
/// Pure Swift, no Python dependency. The output dir is ready to be
/// served by `mox run` directly without going through `MLXNN.quantize`
/// at load time (a 14 GB bf16 model becomes ~4 GB 4-bit, loaded as
/// the `MLXQuantized` branch in the pull router).
public enum MoxQuantError: Error, LocalizedError {
    case unsupportedQuantizationMode(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedQuantizationMode(let s):
            return "unsupported quantization mode: '\(s)' (expected affine or mxfp4/mxfp8)"
        }
    }
}

public struct QuantizationOptions: Sendable {
    public var bits: Int
    public var groupSize: Int
    public var mode: QuantizationMode
    public var outputDirectory: URL

    public init(
        bits: Int = 4,
        groupSize: Int = 64,
        mode: QuantizationMode = .affine,
        outputDirectory: URL
    ) {
        self.bits = bits
        self.groupSize = groupSize
        self.mode = mode
        self.outputDirectory = outputDirectory
    }
}

public enum MoxQuant {

    /// Quantize the model at `sourceDirectory` and write the result to
    /// `options.outputDirectory`. The source directory must already be a
    /// valid HF / mlx-style model directory (config.json + model*.safetensors).
    ///
    /// Returns the on-disk size of the new safetensors file. Callers can
    /// use this to print the size delta vs. the source.
    public static func quantize(
        sourceDirectory: URL,
        options: QuantizationOptions
    ) async throws -> Int64 {
        // Step 1: load via the same path mox-run uses. The container
        // owns the loaded model — we never let the MLXArray escape it.
        let container = try await MLXLMCommon.loadModelContainer(
            from: sourceDirectory,
            using: #huggingFaceTokenizerLoader
        )

        // Step 2 + 3 + 4: everything happens inside the container's
        // isolation actor so the MLXArrays stay alive for the quantize
        // pass and the save call.
        let (outputURL, outputBytes): (URL, Int64) = try await container.perform { context in
            // Step 2: quantize. `context.model` is `any LanguageModel`
            // which conforms to `Module` via BaseLanguageModel, so the
            // existential cast through `as! Module` is sound — the
            // protocol's only refinement is `sanitize(weights:)` which
            // we don't need.
            let module = context.model as! Module
            MLXNN.quantize(
                model: module,
                groupSize: options.groupSize,
                bits: options.bits,
                mode: options.mode
            )

            // Step 3: flatten parameters. The result is the
            // `[String: MLXArray]` dict that the writer expects.
            let weights = module.parameters().flattened()

            // Step 4: write. mlx-swift's `MLX.save(arrays:url:stream:)` picks
            // the format from the URL's extension — we use `.safetensors`.
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
            let outputURL = options.outputDirectory
                .appendingPathComponent("model.safetensors")
            try MLX.save(
                arrays: Dictionary(uniqueKeysWithValues: weights),
                metadata: [
                    "format": "mlx",
                    "quantization": "\(options.bits)bit-\(options.mode)",
                ],
                url: outputURL
            )

            let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            return (outputURL, bytes)
        }

        return outputBytes
    }
}
