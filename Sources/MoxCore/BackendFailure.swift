import Foundation
import MoxDomain
import OSLog

/// Diagnostic values are allowlisted, never taken from error descriptions/userInfo.
/// Unknown coding keys and domains may contain user data and are redacted.
public struct BackendFailure: Error, Sendable {
  public enum Stage: String, Sendable {
    case admission, load, tokenizer, warmup, prepare, generate
  }
  public let stage: Stage
  public let category: String
  public let errorType: String
  public let domain: String
  public let code: Int
  public let codingPath: String
  public let clientError: MoxError

  public init(_ error: any Error, stage: Stage) {
    if let failure = error as? BackendFailure {
      self = failure
      return
    }
    self.stage = stage
    errorType = String(reflecting: type(of: error))
    let ns = error as NSError
    domain =
      [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(ns.domain)
      ? ns.domain : "redacted"
    code = ns.code
    var path: [any CodingKey] = []
    switch error {
    case DecodingError.keyNotFound(let key, let context):
      category = "keyNotFound"
      path = context.codingPath + [key]
    case DecodingError.typeMismatch(_, let context):
      category = "typeMismatch"
      path = context.codingPath
    case DecodingError.valueNotFound(_, let context):
      category = "valueNotFound"
      path = context.codingPath
    case DecodingError.dataCorrupted(let context):
      category = "dataCorrupted"
      path = context.codingPath
    case let known as MoxError: category = known.code.rawValue
    default: category = "backendError"
    }
    let keys: Set<String> = [
      "model_type", "hidden_size", "num_hidden_layers", "num_attention_heads",
      "num_key_value_heads", "head_dim", "max_position_embeddings", "vocab_size",
      "quantization", "bits", "group_size", "tokenizer_class", "chat_template",
      "eos_token", "bos_token", "model", "vocab", "merges", "added_tokens",
    ]
    codingPath = path.prefix(16).map { key in
      if key.intValue != nil { return "[]" }
      return keys.contains(key.stringValue) ? key.stringValue : "<redacted>"
    }.joined(separator: ".")
    clientError =
      (error as? MoxError)
      ?? MoxError(
        [.load, .tokenizer, .warmup].contains(stage) ? .loadFailed : .generationFailed,
        "Backend operation failed; inspect runtime diagnostics and model assets.")
  }

  public func record(modelID: String, requestID: UUID) {
    Logger(subsystem: "dev.mox", category: "runtime").error(
      "model=\(modelID, privacy: .public) request=\(requestID.uuidString, privacy: .public) stage=\(stage.rawValue, privacy: .public) error_type=\(errorType, privacy: .public) category=\(category, privacy: .public) domain=\(domain, privacy: .public) code=\(code) coding_path=\(codingPath, privacy: .public)"
    )
  }
}
