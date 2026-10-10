import CryptoKit
import Foundation
import MoxDomain

public struct LocalModel: Sendable, Hashable {
  public let directory: URL
  public let id: String
  public let modelType: String
  public let weightBytes: Int
  public let contextSize: Int
  public let kvBytesPerToken: Int
  public let workspaceBytes: Int
  public let resources: ModelResources
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
      let url = directory.appendingPathComponent(file).resolvingSymlinksInPath()
      let asset = try ModelAssetFile(url, maximumBytes: 32 * 1024 * 1024)
      let data = try asset.read(count: asset.size)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MoxError(.invalidModel, "Missing or invalid \(file).")
      }
      return object
    }
    let config = try json("config.json")
    _ = try json("tokenizer_config.json")
    _ = try ModelAssetFile(directory.appendingPathComponent("tokenizer.json").resolvingSymlinksInPath(),
      maximumBytes: 64 * 1024 * 1024)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey])
    let weights = files.filter { $0.pathExtension == "safetensors" }
    guard !weights.isEmpty else { throw MoxError(.invalidModel, "Missing safetensors weights.") }
    var tensorFiles: [String: String] = [:]
    for file in weights {
      try Task.checkCancellation()
      for name in try WeightInspection.names(in: file.resolvingSymlinksInPath()) {
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
      let size = try ModelAssetFile(url.resolvingSymlinksInPath()).size
      guard size > 8 else { throw MoxError(.invalidModel, "Empty weight shard.") }
      guard !total.addingReportingOverflow(size).overflow else {
        throw MoxError(.resourceLimit, "Weight size overflow.")
      }
      return total + size
    }
    let resources = try ModelResources(
      configuration: JSONSerialization.data(withJSONObject: config), weightBytes: bytes)
    self.directory = directory
    self.modelType = resources.modelType
    self.contextSize = resources.contextSize
    self.weightBytes = resources.weightBytes
    self.kvBytesPerToken = resources.kvBytesPerToken
    self.workspaceBytes = resources.workspaceBytes
    self.resources = resources
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
        try Task.checkCancellation()
        let target = url.resolvingSymlinksInPath()
        _ = try ModelAssetFile(target)
        let values = try target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return
          "\(url.lastPathComponent):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
      }
    return records.joined(separator: "|")
  }
}
