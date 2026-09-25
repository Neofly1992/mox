import Foundation
import MoxCore
import MoxDomain

public struct DefaultModelSources: ModelSourceFactory {
  private let cacheDirectory: URL
  public init(cacheDirectory: URL) { self.cacheDirectory = cacheDirectory }
  public func saveCredential(_ value: String, registryID: UUID, endpoint: URL) throws -> String {
    try SourceCredentials().save(value, registryID: registryID, endpoint: endpoint)
  }
  public func deleteCredential(reference: String) throws {
    try SourceCredentials().delete(reference: reference)
  }
  public func make(provider: ModelProvider, endpoint: URL, credentialReference: String?) throws -> any ResolvedModelSource {
    let token = try credentialReference.map { try SourceCredentials().read(reference: $0) }
    return switch provider {
    case .huggingFace:
      try HuggingFaceSource(endpoint: endpoint, token: token, cacheDirectory: cacheDirectory)
    case .modelScope:
      try ModelScopeSource(endpoint: endpoint, token: token)
    }
  }
}
