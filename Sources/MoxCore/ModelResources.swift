import Foundation
import MoxDomain

/// Dense, full-attention upper envelope. Sliding attention is counted as full attention;
/// unsupported/hybrid layouts must not borrow these numbers. Units are bytes and tokens.
public struct ModelResources: Sendable, Hashable {
  private static let recommendedBudgetFraction = 0.8
  private static let float32Bytes = 4
  // Conservative live-buffer allowances for projections/MLP and per-layer prefill.
  private static let temporaryBufferCopies = 4
  // Gemma2 in LM 3.31.4 materializes matmul/softcap/mask/softmax attention scores.
  // Reserve eight Float32 score buffers rather than treating it as fused attention.
  private static let explicitAttentionScoreCopies = 8
  public static let prefillStepTokens = 128
  public static let minimumWorkspaceBytes = 64 * 1024 * 1024
  public let weightBytes: Int
  public let contextSize: Int
  public let kvBytesPerToken: Int
  public let workspaceBytes: Int
  private let baseWorkspaceBytes: Int
  private let scoreBytesPerToken: Int
  public let modelType: String
  public init(configuration: Data, weightBytes: Int) throws {
    guard configuration.count <= 8 * 1024 * 1024,
      let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
      let type = config["model_type"] as? String,
      ["qwen2", "qwen3", "llama", "gemma", "gemma2", "gemma3_text", "mistral", "phi3"].contains(
        type)
    else { throw MoxError(.invalidModel, "Model architecture has no verified resource estimate.") }
    func positive(_ key: String, fallback: Int? = nil) throws -> Int {
      guard let value = (config[key] as? Int) ?? fallback, value > 0, value <= 10_000_000 else {
        throw MoxError(.invalidModel, "Missing or invalid model dimension: \(key).")
      }
      return value
    }
    let layers = try positive("num_hidden_layers")
    let hidden = try positive("hidden_size")
    let intermediate = try positive("intermediate_size")
    let heads = try positive("num_attention_heads")
    let kvFallback: Int? =
      type == "llama" || type == "mistral"
      ? heads
      : type == "gemma3_text" ? 1 : nil
    let kvHeads = try positive("num_key_value_heads", fallback: kvFallback)
    let headDim: Int
    switch type {
    case "qwen2", "phi3":
      // Locked adapters derive this value and ignore optional head_dim metadata.
      guard hidden % heads == 0 else {
        throw MoxError(.invalidModel, "Attention dimensions are inconsistent.")
      }
      headDim = hidden / heads
    case "llama", "mistral": headDim = try positive("head_dim", fallback: hidden / heads)
    case "gemma3_text": headDim = try positive("head_dim", fallback: 256)
    default: headDim = try positive("head_dim")
    }
    guard kvHeads <= heads, heads % kvHeads == 0 else {
      throw MoxError(.invalidModel, "Attention head groups are inconsistent.")
    }
    contextSize = try positive("max_position_embeddings")
    let vocab = try positive("vocab_size")
    let scalarBytes = Double(Self.float32Bytes)
    let temporaryBytes = Double(Self.temporaryBufferCopies) * scalarBytes
    let kv = Double(layers) * 2 * Double(kvHeads) * Double(headDim) * scalarBytes
    let step = Double(Self.prefillStepTokens)
    let scoreTokens = min(
      contextSize, GenerationLimits.maximumInputTokens + GenerationLimits.maximumOutputTokens)
    let scorePerToken =
      type == "gemma2"
      ? Double(heads) * step * scalarBytes * Double(Self.explicitAttentionScoreCopies) : 0
    let baseWork =
      max(Double(hidden) * Double(hidden), Double(intermediate) * step * 2) * temporaryBytes
      + Double(vocab) * step * scalarBytes
      + step * Double(hidden) * Double(layers) * temporaryBytes
    let work = baseWork + scorePerToken * Double(scoreTokens)
    guard kv < Double(Int.max / 10_000_000), work < Double(Int.max / 4),
      weightBytes > 0, weightBytes < Int.max / 4
    else {
      throw MoxError(.resourceLimit, "Model dimensions exceed safe estimation limits.")
    }
    self.weightBytes = weightBytes
    modelType = type
    kvBytesPerToken = Int(kv)
    baseWorkspaceBytes = Int(baseWork)
    scoreBytesPerToken = Int(scorePerToken)
    workspaceBytes = max(Self.minimumWorkspaceBytes, Int(work))
  }
  public func assessment(
    maxTokens: Int, budgetBytes: Int, residentBytes: Int = 0,
    alreadyResident: Bool = false, admissionPressure: MemoryPressureLevel = .normal
  ) -> ResourceAssessment {
    // Tokenizer/template output is unavailable until load. Reserving the entire allowed
    // input envelope avoids guessing from character counts; adapter checks exact tokens.
    guard (1...GenerationLimits.maximumOutputTokens).contains(maxTokens), residentBytes >= 0,
      budgetBytes >= 0
    else {
      return .unknown(budgetBytes: max(0, budgetBytes), reason: "Invalid resource preview limits.")
    }
    guard maxTokens < contextSize else {
      return .init(
        status: .exceedsBudget, weightBytes: weightBytes, budgetBytes: budgetBytes,
        contextTokens: contextSize,
        reason: "Requested output leaves no room for input within the model context.",
        suggestion: "Choose fewer output tokens; Mox does not silently change the request.")
    }
    let tokens = min(contextSize, GenerationLimits.maximumInputTokens + maxTokens)
    let kv = kvBytesPerToken * tokens
    let requestWorkspace = max(
      Self.minimumWorkspaceBytes, baseWorkspaceBytes + scoreBytesPerToken * tokens)
    let overhead = alreadyResident ? 0 : weightBytes
    let newWeights = alreadyResident ? 0 : weightBytes
    let requestPeak = newWeights + overhead + kv + requestWorkspace
    guard !residentBytes.addingReportingOverflow(requestPeak).overflow else {
      return .unknown(budgetBytes: budgetBytes, reason: "Resource estimate overflow.")
    }
    let peak = residentBytes + requestPeak
    let status: ResourceStatus =
      admissionPressure != .normal || peak > budgetBytes
      ? .exceedsBudget
      : Double(peak) > Double(budgetBytes) * Self.recommendedBudgetFraction
        ? .constrained : .recommended
    let pressureExplanation =
      admissionPressure == .normal
      ? ""
      : "Memory pressure \(admissionPressure.rawValue) pauses new work; wait for 5 seconds of normal pressure. "
    return .init(
      status: status, weightBytes: weightBytes, loadOverheadBytes: overhead,
      kvBytes: kv, workspaceBytes: requestWorkspace, residentBytes: residentBytes,
      peakBytes: peak, budgetBytes: budgetBytes, contextTokens: tokens,
      maximumOutputTokens: maxTokens,
      reason:
        pressureExplanation
        + "Dense attention envelope: stored safetensors bytes, one extra weight copy on load, Float32 K+V, bounded 128-token prefill workspace (Gemma2 includes explicit attention score buffers). Input allowance up to 8192 tokens plus requested output; exact context validated after tokenization. CPU/tokenizer/allocator costs remain uncertain. Single GPU peak; queued requests do not allocate KV.",
      suggestion: status == .recommended
        ? "Expected headroom; no performance or absolute safety guarantee."
        : "Choose smaller weights or fewer output tokens; unload idle models. Input allowance is conservative and is not silently shortened."
    )
  }
}
