import CryptoKit
import Foundation
import MoxDomain

public struct LocalModel: Sendable, Hashable {
  public let directory: URL
  public let id: String
  public let weightBytes: Int
  public let contextSize: Int
  public let kvBytesPerToken: Int
  public let workspaceBytes: Int
  private let fingerprint: String

  public init(path: String) throws {
    let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MoxError(.invalidModel, "Model directory does not exist.")
    }
    func json(_ file: String) throws -> [String: Any] {
      let url = directory.appendingPathComponent(file)
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 32 * 1024 * 1024,
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw MoxError(.invalidModel, "Missing or invalid \(file).")
      }
      return object
    }
    let config = try json("config.json")
    _ = try json("tokenizer_config.json")
    guard
      FileManager.default.isReadableFile(
        atPath: directory.appendingPathComponent("tokenizer.json").path)
    else { throw MoxError(.invalidModel, "Missing tokenizer.json.") }
    guard
      let tokenizerSize = try? directory.appendingPathComponent("tokenizer.json").resourceValues(
        forKeys: [.fileSizeKey]).fileSize,
      tokenizerSize <= 64 * 1024 * 1024
    else {
      throw MoxError(.resourceLimit, "tokenizer.json exceeds the 64 MiB asset metadata budget.")
    }
    // These dense attention layouts have a defensible KV/working-space estimate.
    // Other factory architectures need their own estimator before admission.
    guard let type = config["model_type"] as? String,
      ["qwen2", "qwen3", "llama", "gemma", "gemma2", "gemma3_text", "mistral", "phi3"].contains(
        type)
    else {
      throw MoxError(.invalidModel, "Model architecture has no verified M1 resource estimate.")
    }
    func positive(_ key: String, fallback: Int? = nil) throws -> Int {
      guard let value = (config[key] as? Int) ?? fallback, value > 0, value <= 10_000_000 else {
        throw MoxError(.invalidModel, "Missing or invalid model dimension: \(key).")
      }
      return value
    }
    let layers = try positive("num_hidden_layers")
    let hidden = try positive("hidden_size")
    let heads = try positive("num_attention_heads")
    let kvHeads = try positive("num_key_value_heads", fallback: heads)
    let headDim = try positive("head_dim", fallback: hidden / heads)
    let context = try positive("max_position_embeddings")
    let vocab = try positive("vocab_size")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey])
    let weights = files.filter { $0.pathExtension == "safetensors" }
    guard !weights.isEmpty else { throw MoxError(.invalidModel, "Missing safetensors weights.") }
    var tensorFiles: [String: String] = [:]
    for file in weights {
      for name in try WeightInspection.names(in: file) {
        guard tensorFiles.updateValue(file.lastPathComponent, forKey: name) == nil else {
          throw MoxError(.invalidModel, "Duplicate weight tensor across shards.")
        }
      }
    }
    if files.contains(where: { $0.lastPathComponent == "model.safetensors.index.json" }) {
      let index = try json("model.safetensors.index.json")
      guard let map = index["weight_map"] as? [String: String], !map.isEmpty else {
        throw MoxError(.invalidModel, "Invalid weight index.")
      }
      let indexed = Set(map.values)
      guard indexed == Set(weights.map(\.lastPathComponent)), map == tensorFiles else {
        throw MoxError(.invalidModel, "Weight shards and index do not match.")
      }
    } else if weights.count != 1 {
      throw MoxError(.invalidModel, "Sharded weights require model.safetensors.index.json.")
    }
    let bytes = try weights.reduce(0) { total, url in
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 8 else { throw MoxError(.invalidModel, "Empty weight shard.") }
      return total + size
    }
    // Float32 KV upper estimate; prefill step is bounded at 128 in the adapter.
    let kv = Double(layers) * 2 * Double(kvHeads) * Double(headDim) * 4
    let work =
      Double(hidden) * Double(hidden) * 16 + Double(vocab) * 128 * 4 + 128 * Double(hidden)
      * Double(layers) * 16
    guard kv < Double(Int.max / 10_000_000), work < Double(Int.max / 4), bytes < Int.max / 4 else {
      throw MoxError(.resourceLimit, "Model dimensions exceed safe estimation limits.")
    }
    self.directory = directory
    self.contextSize = context
    self.weightBytes = bytes
    self.kvBytesPerToken = Int(kv)
    self.workspaceBytes = max(64 * 1024 * 1024, Int(work))
    self.id = LocalModelIdentity.identifier(for: directory)
    self.fingerprint = try Self.fingerprint(directory)
  }
  public func validateUnchanged() throws {
    guard try Self.fingerprint(directory) == fingerprint else {
      throw MoxError(.invalidModel, "Referenced model assets changed; open a new reference.")
    }
  }
  private static func fingerprint(_ directory: URL) throws -> String {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    let records = try files.filter { ["json", "safetensors", "jinja"].contains($0.pathExtension) }
      .sorted { $0.path < $1.path }.map { url in
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return
          "\(url.lastPathComponent):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
      }
    return records.joined(separator: "|")
  }
}
