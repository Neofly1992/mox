import Foundation
import HuggingFace
import MoxCore
import MoxDomain

public struct HuggingFaceSource: ResolvedModelSource {
  private let client: HubClient
  private let transport: SourceTransport
  public init(endpoint: URL = URL(string: "https://huggingface.co")!, token: String? = nil, cacheDirectory: URL) throws {
    transport = try SourceTransport(endpoint: endpoint, token: token)
    client = HubClient(session: transport.session, host: endpoint,
      tokenProvider: token.map { .fixed(token: $0) } ?? .none,
      cache: HubCache(location: .fixed(directory: cacheDirectory)))
  }
  public func resolve(registryID: UUID, repository: String, selector: String, variant: String = "") async throws -> ArtifactManifest {
    try ArtifactValidation.relativePath(repository)
    guard let repo = Repo.ID(rawValue: repository) else {
      throw MoxError(.invalidParameters, "Expected owner/repository.")
    }
    let model = try await client.getModel(repo, revision: selector)
    guard let revision = model.sha else { throw MoxError(.invalidModel, "HF did not return a fixed revision.") }
    var page = try await client.listTree(in: repo, revision: revision, recursive: true)
    var entries = page.items
    while let next = try await client.nextPage(after: page) {
      guard entries.count + next.items.count <= ArtifactValidation.maximumFiles else {
        throw MoxError(.resourceLimit, "Repository file inventory exceeds its limit.")
      }
      entries += next.items
      page = next
    }
    let files = try entries.filter { $0.type == .file && ModelAssetSelection.includes($0.path, variant: variant) }.map { entry in
      guard let bytes = entry.effectiveSize, let hash = entry.lfs?.oid ?? entry.oid else {
        throw MoxError(.invalidModel, "HF did not supply file integrity evidence.")
      }
      return ArtifactFile(path: entry.path, bytes: Int64(bytes),
        digest: entry.lfs == nil ? .gitBlobSHA1(hash) : .sha256(hash))
    }
    let manifest = ArtifactManifest(origin: .init(registryID: registryID, repository: repository, revision: revision, variant: variant), files: files)
    try ArtifactValidation.validate(manifest)
    try ModelAssetSelection.validate(files, variant: variant)
    return manifest
  }
  public func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    try ArtifactValidation.validate(manifest)
    guard manifest.files.contains(file) else { throw MoxError(.invalidParameters, "File is not part of the fixed snapshot.") }
    let request = try transport.request(path: "\(manifest.origin.repository)/resolve/\(manifest.origin.revision)/\(file.path)")
    try await transport.download(file, request: request, to: root)
  }

}
