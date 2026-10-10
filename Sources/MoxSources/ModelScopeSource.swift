import Foundation
import MoxCore
import MoxDomain

/// Native adapter for the official Hub HTTP protocol. Commit resolution is separate
/// from listing: file.Revision denotes a last modification, not the repository HEAD.
public struct ModelScopeSource: ResolvedModelSource {
  private let transport: SourceTransport
  public init(endpoint: URL = URL(string: "https://modelscope.cn")!, token: String? = nil) throws {
    transport = try SourceTransport(endpoint: endpoint, token: token)
  }
  public func resolve(registryID: UUID, repository: String, selector: String, variant: String = "") async throws -> ArtifactManifest {
    try ArtifactValidation.relativePath(repository)
    guard repository.split(separator: "/").count == 2, !selector.isEmpty, selector.utf8.count <= 256 else {
      throw MoxError(.invalidParameters, "Expected owner/repository and a revision.")
    }
    let prefix = "api/v1/models/\(repository)"
    let commits = try JSONDecoder().decode(
      CommitResponse.self,
      from: await transport.json(
        path: "\(prefix)/commits",
        query: [
          .init(name: "Revision", value: selector), .init(name: "PageNumber", value: "1"),
          .init(name: "PageSize", value: "1"),
        ]))
    guard commits.Success, let revision = commits.Data?.Commit.first?.Id else {
      throw MoxError(.invalidModel, "ModelScope could not resolve an immutable repository revision.")
    }
    let response = try JSONDecoder().decode(
      FilesResponse.self,
      from: await transport.json(
        path: "\(prefix)/repo/files",
        query: [
          .init(name: "Revision", value: revision), .init(name: "Recursive", value: "true"),
        ]))
    guard response.Success, let entries = response.Data?.Files, entries.count < 3_000 else {
      throw MoxError(.invalidModel, "ModelScope file listing failed or was truncated.")
    }
    let files = try entries.filter { $0.kind == "blob" && ModelAssetSelection.includes($0.Path, variant: variant) }.map { entry in
      guard let hash = entry.Sha256, let bytes = entry.Size else {
        throw MoxError(.invalidModel, "ModelScope did not supply file integrity evidence.")
      }
      return ArtifactFile(path: entry.Path, bytes: bytes, digest: .sha256(hash))
    }
    let manifest = ArtifactManifest(origin: .init(
      registryID: registryID, repository: repository, revision: revision, variant: variant), files: files)
    try ArtifactValidation.validate(manifest)
    try ModelAssetSelection.validate(files, variant: variant)
    return manifest
  }
  public func resourceConfiguration(_ manifest: ArtifactManifest) async throws -> Data? {
    let name =
      manifest.origin.variant.isEmpty ? "config.json" : manifest.origin.variant + "/config.json"
    guard let file = manifest.files.first(where: { $0.path == name }), file.bytes <= 8 * 1024 * 1024
    else { return nil }
    return try await transport.json(
      path: "api/v1/models/\(manifest.origin.repository)/repo",
      query: [
        .init(name: "Revision", value: manifest.origin.revision),
        .init(name: "FilePath", value: file.path),
      ])
  }
  public func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws
  {
    try ArtifactValidation.validate(manifest)
    guard manifest.files.contains(file) else {
      throw MoxError(.invalidParameters, "File is not part of the fixed snapshot.")
    }
    let request = try transport.request(
      path: "api/v1/models/\(manifest.origin.repository)/repo",
      query: [
        .init(name: "Revision", value: manifest.origin.revision),
        .init(name: "FilePath", value: file.path),
      ])
    try await transport.download(file, request: request, to: root)
  }

  private struct CommitResponse: Decodable {
    let Success: Bool
    let Data: CommitData?
  }
  private struct CommitData: Decodable { let Commit: [Commit] }
  private struct Commit: Decodable { let Id: String }
  private struct FilesResponse: Decodable {
    let Success: Bool
    let Data: FilesData?
  }
  private struct FilesData: Decodable { let Files: [Entry] }
  private struct Entry: Decodable {
    let Path: String
    let kind: String
    enum CodingKeys: String, CodingKey {
      case Path, Sha256, Size
      case kind = "Type"
    }
    let Sha256: String?
    let Size: Int64?
  }
}

/// Select inference assets, never training checkpoints or executable repository code.
/// The installer still runs LocalModel validation before publishing availability.
enum ModelAssetSelection {
  static func includes(_ path: String, variant: String) -> Bool {
    let prefix = variant.isEmpty ? "" : variant + "/"
    guard path.hasPrefix(prefix) else { return false }
    let name = String(path.dropFirst(prefix.count))
    guard !name.contains("/") else { return false }
    return name.hasSuffix(".safetensors")
      || [
        "config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json",
        "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt",
        "tokenizer.model",
        "chat_template.jinja", "generation_config.json", "preprocessor_config.json",
        "processor_config.json",
      ].contains(name)
  }
  static func validate(_ files: [ArtifactFile], variant: String) throws {
    let prefix = variant.isEmpty ? "" : variant + "/"
    let names = Set(files.map { String($0.path.dropFirst(prefix.count)) })
    guard ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy(names.contains),
      names.contains(where: { $0.hasSuffix(".safetensors") }) else {
      throw MoxError(.invalidModel, "Repository does not contain the required MLX inference assets.")
    }
  }
}
