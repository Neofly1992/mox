import Foundation
import MoxDomain

public struct LibraryChanges: Sendable {
  public var configuration: ModelConfiguration?
  public var installations: [ModelInstallation] = []
  public var operations: [DownloadOperation] = []
  public var removedInstallations: [UUID] = []
  public var removedOperations: [UUID] = []
  public init(
    configuration: ModelConfiguration? = nil,
    installations: [ModelInstallation] = [], operations: [DownloadOperation] = [],
    removedInstallations: [UUID] = [], removedOperations: [UUID] = []
  ) {
    self.configuration = configuration
    self.installations = installations
    self.operations = operations
    self.removedInstallations = removedInstallations
    self.removedOperations = removedOperations
  }
}
public enum InstallationLookup: Sendable {
  case id(UUID)
  case alias(String)
  case path(String)
  case origin(ArtifactOrigin)
}
public protocol ModelLibraryPersistence: Sendable {
  func configuration() async throws -> ModelConfiguration
  func installation(_ lookup: InstallationLookup) async throws -> ModelInstallation?
  func operation(_ id: UUID) async throws -> DownloadOperation?
  func installations(offset: Int, limit: Int) async throws -> [ModelInstallation]
  func operations(offset: Int, limit: Int) async throws -> [DownloadOperation]
  func installationSummaries(offset: Int, limit: Int) async throws -> [ModelInstallationSummary]
  func operationSummaries(offset: Int, limit: Int) async throws -> [DownloadOperationSummary]
  func installationCount() async throws -> Int
  func operationCount() async throws -> Int
  func activeOperationCount() async throws -> Int
  func operations(origin: ArtifactOrigin, offset: Int, limit: Int) async throws
    -> [DownloadOperation]
  func hasUnfinishedOperation(origin: ArtifactOrigin) async throws -> Bool
  func relatedInstallations(origin: ArtifactOrigin, offset: Int, limit: Int) async throws
    -> [ModelInstallation]
  func commit(_ changes: LibraryChanges) async throws
}
public protocol ModelFileSource: Sendable {
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws
}

public protocol ResolvedModelSource: ModelFileSource {
  func resolve(registryID: UUID, repository: String, selector: String, variant: String) async throws
    -> ArtifactManifest
}
public protocol ModelSourceFactory: Sendable {
  func saveCredential(_ value: String, registryID: UUID, endpoint: URL) throws -> String
  func deleteCredential(reference: String) throws
  func make(provider: ModelProvider, endpoint: URL, credentialReference: String?) throws
    -> any ResolvedModelSource
}
