import Foundation
import MoxDomain

/// Capability evidence is tied to a pinned artifact, not an architecture name.
public enum VerifiedToolModel {
  public static func supports(_ item: ModelInstallation) -> Bool {
    guard let manifest = item.manifest,
      manifest.origin.repository == "mlx-community/Qwen3-0.6B-4bit",
      manifest.origin.revision == "73e3e38d981303bc594367cd910ea6eb48349da8",
      manifest.origin.variant.isEmpty,
      manifest.files.contains(where: { $0.path == "model.safetensors" &&
        $0.digest == .sha256("392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2") }),
      manifest.files.contains(where: { $0.path == "tokenizer.json" &&
        $0.digest == .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4") })
    else { return false }
    return true
  }
}

