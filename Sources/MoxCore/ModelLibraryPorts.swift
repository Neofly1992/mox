import Foundation
import MoxDomain

public protocol ModelLibraryPersistence: Sendable {
  func readLibrary() async throws -> ModelLibrarySnapshot
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) async throws
}
public protocol ModelFileSource: Sendable {
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws
}

public protocol ResolvedModelSource: ModelFileSource {
  func resolve(registryID: UUID, repository: String, selector: String, variant: String) async throws -> ArtifactManifest
}
public protocol ModelSourceFactory: Sendable {
  func saveCredential(_ value: String, registryID: UUID, endpoint: URL) throws -> String
  func deleteCredential(reference: String) throws
  func make(provider: ModelProvider, endpoint: URL, credentialReference: String?) throws -> any ResolvedModelSource
}
