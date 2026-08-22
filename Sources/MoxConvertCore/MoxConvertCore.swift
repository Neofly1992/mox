import Foundation
import MoxShared

// MARK: - MoxConverter (v0.5)
//
// v0.5 ships smart pull routing only. Re-quantization and bf16→MLX
// conversion are deferred to v0.5.x because mlx-swift does not yet
// expose a public API for serializing an `MLX.nn.Module` to safetensors.
//
// This file is intentionally tiny: it owns only the model-directory
// probe (`ModelProbe` + `inspect(at:)`). The on-disk manifest schema lives
// in `MoxShared.ModelManifest`; MoxConvertCore does not redefine it.

public enum ModelProbe: Equatable, Sendable, Codable {
    case mlxQuantized
    case hfPrecision(dtype: String)
    case unknown(reason: String)
}

/// Internal HF config.json decoder. Not part of the public API: callers
/// only ever see a `ModelProbe` value.
struct HFConfig: Codable, Sendable {
    let architectures: [String]?
    let modelType: String?
    let torchDtype: String?
    let quantizationConfig: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case architectures
        case modelType = "model_type"
        case torchDtype = "torch_dtype"
        case quantizationConfig = "quantization_config"
    }
}

public enum ProbeError: Error, LocalizedError {
    case ioError(URL)

    public var errorDescription: String? {
        switch self {
        case .ioError(let url):
            return "Failed to read \(url.path)"
        }
    }
}

/// v0.5 routing helper. `mox pull` calls this on every pulled model
/// directory to decide what to do with it.
public struct MoxConverter: Sendable {

    public init() {}

    /// Read the `config.json` of `directory` and classify the model.
    ///
    /// - Returns `.mlxQuantized` if a `quantization_config` field exists.
    /// - Returns `.hfPrecision(dtype:)` if the model is HuggingFace bf16/fp16/fp32.
    /// - Returns `.unknown(reason:)` otherwise — including when `config.json`
    ///   is absent, or when neither `model_type` nor `torch_dtype` can be
    ///   decoded. This is the behaviour the design contract specifies:
    ///   missing data is reported, not raised, so `mox pull` can still
    ///   succeed for legacy or foreign model directories.
    public func inspect(at directory: URL) throws -> ModelProbe {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .unknown(reason: "config.json missing at \(directory.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ProbeError.ioError(configURL)
        }
        let config: HFConfig
        do {
            config = try JSONDecoder().decode(HFConfig.self, from: data)
        } catch {
            throw ProbeError.ioError(configURL)
        }

        if config.quantizationConfig != nil {
            return .mlxQuantized
        }
        if config.modelType == nil {
            return .unknown(reason: "config.json has no model_type")
        }
        // Truthful reporting: do NOT default to "bf16" when the config
        // never declared `torch_dtype` — claim the precision the file
        // actually asserts, and call out the missing field explicitly.
        guard let dtype = config.torchDtype, !dtype.isEmpty else {
            return .unknown(reason: "config.json has no torch_dtype")
        }
        return .hfPrecision(dtype: dtype)
    }
}