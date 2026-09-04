import Foundation
import MoxShared

/// Picks a sensible default model id based on the host hardware.
///
/// The thresholds mirror MTPLX's recommendation table:
/// - < 16 GB total RAM → 0.5B–1.5B (toy / dev)
/// - 16–32 GB → 7B–9B
/// - 32–64 GB → 14B–27B
/// - 64 GB+ → 27B–35B / MoE
///
/// Caller decides whether to act on the suggestion — `mox -m`
/// without a model id prints the recommendation and waits for
/// confirmation, instead of auto-launching.
public struct DefaultModelSuggester: Sendable {

    /// What we suggest, in priority order. Caller can pick the
    /// first id that's locally installed (via `listModels`) and
    /// prompt the user otherwise.
    public struct Suggestion: Sendable, Equatable {
        public let recommendedIDs: [String]
        public let totalRAMGB: Int
        public let tier: Tier
        public let notes: String

        public enum Tier: String, Sendable, Equatable {
            case toy      // < 16 GB
            case small    // 16-32 GB
            case medium   // 32-64 GB
            case large    // 64 GB+
        }
    }

    public init() {}

    /// Inspect the host and produce a suggestion. The actual model
    /// ids live in the M2/M3 ecosystem — we use the well-known
    /// community defaults so the suggestion is informative without
    /// committing to a curated catalog (mox doesn't ship one).
    public func suggest(for hardware: HardwareClassifier) -> Suggestion {
        let ramGB = Int(hardware.totalMemoryBytes >> 30)
        let tier: Suggestion.Tier
        let ids: [String]
        let note: String

        if !hardware.isAppleSilicon {
            tier = .toy
            ids = [
                "Qwen/Qwen2.5-0.5B-Instruct",
                "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
            ]
            note = "Intel Mac detected — MLX won't run; consider running under Rosetta or switching to a non-MLX backend (not supported yet)."
        } else if ramGB < 16 {
            tier = .toy
            ids = [
                "Qwen/Qwen2.5-0.5B-Instruct",
                "Qwen/Qwen2.5-1.5B-Instruct",
                "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
            ]
            note = "Less than 16 GB total RAM — stick to sub-2B models for reasonable speed."
        } else if ramGB < 32 {
            tier = .small
            ids = [
                "mlx-community/Qwen2.5-7B-Instruct-4bit",
                "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
                "mlx-community/Qwen2.5-3B-Instruct-4bit",
            ]
            note = "16-32 GB RAM — 7-9B 4-bit is the sweet spot."
        } else if ramGB < 64 {
            tier = .medium
            ids = [
                "mlx-community/Qwen2.5-14B-Instruct-4bit",
                "mlx-community/Meta-Llama-3.1-70B-Instruct-4bit",
                "mlx-community/Qwen2.5-32B-Instruct-4bit",
            ]
            note = "32-64 GB RAM — 14-27B 4-bit fits comfortably."
        } else {
            tier = .large
            ids = [
                "mlx-community/Qwen2.5-32B-Instruct-4bit",
                "mlx-community/Meta-Llama-3.1-70B-Instruct-4bit",
                "mlx-community/Qwen2.5-72B-Instruct-4bit",
            ]
            note = "64 GB+ RAM — 27B+ 4-bit or 70B+ 4-bit; consider a 35B MoE."
        }
        return Suggestion(
            recommendedIDs: ids,
            totalRAMGB: ramGB,
            tier: tier,
            notes: note
        )
    }
}