import Foundation
import MoxShared

/// Probe a model directory and classify compatibility with mox's runtime.
/// The probe is **deliberately conservative** — `unknown` is a safe
/// outcome, `incompatible` is a hard refusal. The contract:
///
/// 1. If `config.json` is missing or unreadable → `.unknown(reason:)`.
/// 2. If `model_type` is absent → `.unknown(reason:)` — never guess.
/// 3. If the model_type matches the curated `mlxBuiltinFamilies` set and a
///    `quantization_config` is present → `.mlxBuiltin`.
/// 4. If the model_type matches but the architecture is community-only
///    (e.g. an archived Mistral variant) → `.communityUnverified`.
/// 5. If the model_type is recognised by HuggingFace but has no first-
///    class path in mlx-swift-lm → `.arOnly` (target-only AR works).
/// 6. Anything else → `.incompatible(reason:)`.
public enum CompatibilityProbe {

    /// Model types mox trusts to load via mlx-swift-lm's standard path.
    /// The list is intentionally tight; we add families as we test them.
    static let mlxBuiltinFamilies: Set<String> = [
        "llama",
        "qwen2",
        "qwen2_moe",
        "qwen3",
        "qwen3_moe",
        "mistral",
        "gemma",
        "gemma2",
        "gemma3",
        "phi",
        "phi3",
        "smollm",
        "starcoder2",
        "deepseek",
        "deepseek_v2",
        "deepseek_v3",
        "internlm",
        "cohere",
        "olmo",
        "openelm",
    ]

    /// Model types that have a working AR path but no MTP / prefix /
    /// tool-call helpers yet.
    static let arOnlyFamilies: Set<String> = [
        "mixtral",
        "mpt",
        "falcon",
        "gpt_neox",
        "baichuan",
        "chatglm",
        "qwen",
        "qwen_moe",
    ]

    public static func probe(at directory: URL) throws -> ModelCompatibility {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return ModelCompatibility(
                tier: .unknown,
                reason: "config.json missing at \(directory.path)",
                modelType: nil
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            return ModelCompatibility(
                tier: .unknown,
                reason: "config.json unreadable: \(error.localizedDescription)",
                modelType: nil
            )
        }
        struct ConfigHead: Decodable {
            let modelType: String?
            let quantizationConfig: AnyCodable?
            enum CodingKeys: String, CodingKey {
                case modelType = "model_type"
                case quantizationConfig = "quantization_config"
            }
        }
        let head: ConfigHead
        do {
            head = try JSONDecoder().decode(ConfigHead.self, from: data)
        } catch {
            return ModelCompatibility(
                tier: .unknown,
                reason: "config.json decode failed: \(error.localizedDescription)",
                modelType: nil
            )
        }
        guard let modelType = head.modelType, !modelType.isEmpty else {
            return ModelCompatibility(
                tier: .unknown,
                reason: "config.json has no model_type",
                modelType: nil
            )
        }
        if mlxBuiltinFamilies.contains(modelType) {
            return ModelCompatibility(
                tier: head.quantizationConfig == nil ? .communityUnverified : .mlxBuiltin,
                reason: head.quantizationConfig == nil
                    ? "no quantization_config in config.json — community build"
                    : "matched mlx-swift-lm first-class path",
                modelType: modelType
            )
        }
        if arOnlyFamilies.contains(modelType) {
            return ModelCompatibility(
                tier: .arOnly,
                reason: "AR-only path; no speculative-decoding support yet",
                modelType: modelType
            )
        }
        return ModelCompatibility(
            tier: .incompatible,
            reason: "model_type '\(modelType)' has no mlx-swift-lm path",
            modelType: modelType
        )
    }

    /// Cheap re-probe at model-load time. The probe is idempotent and
    /// safe to call from any thread. If the persisted manifest tier
    /// disagrees with the fresh probe, the caller surfaces the diff
    /// rather than overwriting it.
    public static func compare(
        directory: URL,
        manifestTier: CompatibilityTier
    ) -> ProbeVerdict {
        let fresh = (try? probe(at: directory))?.tier ?? .unknown
        if fresh == manifestTier { return .match(fresh) }
        return .mismatch(persisted: manifestTier, fresh: fresh)
    }
}

public enum ProbeVerdict: Equatable {
    case match(CompatibilityTier)
    case mismatch(persisted: CompatibilityTier, fresh: CompatibilityTier)
}