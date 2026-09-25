import Foundation

public enum DownloadPhase: String, Codable, Sendable {
  case downloading, paused, verifying, committing, installed, failed, interrupted, cancelled
  public var isActive: Bool { self == .downloading || self == .verifying || self == .committing }
}
public struct DownloadOperation: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let provider: ModelProvider
  public let endpoint: URL
  public let manifest: ArtifactManifest
  public var phase: DownloadPhase
  public var verifiedBytes: Int64
  public var errorCode: String?
  public init(provider: ModelProvider, endpoint: URL, manifest: ArtifactManifest) {
    id = UUID(); self.provider = provider; self.endpoint = endpoint; self.manifest = manifest
    phase = .paused; verifiedBytes = 0
  }
}
public enum ModelAvailability: String, Codable, Sendable { case ready, missing, corrupt }
public struct ModelInstallation: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let path: String
  public let manifest: ArtifactManifest?
  public var alias: String
  public var deletionPending: Bool = false
  public var availability: ModelAvailability = .ready
  public init(id: UUID = UUID(), path: String, manifest: ArtifactManifest?, alias: String) {
    self.id = id; self.path = path; self.manifest = manifest; self.alias = alias
  }
  private enum CodingKeys: String, CodingKey {
    case id, path, manifest, alias, deletionPending, availability
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    path = try values.decode(String.self, forKey: .path)
    manifest = try values.decodeIfPresent(ArtifactManifest.self, forKey: .manifest)
    alias = try values.decode(String.self, forKey: .alias)
    deletionPending = try values.decodeIfPresent(Bool.self, forKey: .deletionPending) ?? false
    availability = try values.decodeIfPresent(ModelAvailability.self, forKey: .availability) ?? .ready
  }
}
public struct ModelLibrarySnapshot: Codable, Sendable {
  public var installations: [ModelInstallation]
  public var operations: [DownloadOperation]
  public var configuration: ModelConfiguration = .defaults
  public init(installations: [ModelInstallation] = [], operations: [DownloadOperation] = []) {
    self.installations = installations; self.operations = operations
  }
  private enum CodingKeys: String, CodingKey { case installations, operations, configuration }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    installations = try values.decode([ModelInstallation].self, forKey: .installations)
    operations = try values.decode([DownloadOperation].self, forKey: .operations)
    configuration = try values.decodeIfPresent(ModelConfiguration.self, forKey: .configuration) ?? .defaults
  }
}

/// Bounded transport view. Full manifests stay in the service-owned store.
public struct ModelInstallationSummary: Codable, Sendable, Identifiable {
  public let id: UUID
  public let path: String
  public let alias: String
  public let origin: ArtifactOrigin?
  public let availability: ModelAvailability
  public let deletionPending: Bool
  public let fileCount: Int
  public let totalBytes: Int64
  public init(_ item: ModelInstallation) {
    id = item.id; path = item.path; alias = item.alias
    origin = item.manifest?.origin; availability = item.availability
    deletionPending = item.deletionPending
    fileCount = item.manifest?.files.count ?? 0
    totalBytes = item.manifest?.files.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
  }
}
public struct DownloadOperationSummary: Codable, Sendable, Identifiable {
  public let id: UUID
  public let origin: ArtifactOrigin
  public let phase: DownloadPhase
  public let verifiedBytes: Int64
  public let totalBytes: Int64
  public let fileCount: Int
  public let errorCode: String?
  public init(_ item: DownloadOperation) {
    id = item.id; origin = item.manifest.origin; phase = item.phase
    verifiedBytes = item.verifiedBytes
    totalBytes = item.manifest.files.reduce(0) { $0 + $1.bytes }
    fileCount = item.manifest.files.count; errorCode = item.errorCode
  }
}
public struct ModelLibraryPage: Codable, Sendable {
  public let installations: [ModelInstallationSummary]
  public let operations: [DownloadOperationSummary]
  public let configuration: ModelConfiguration
  public let installationOffset: Int
  public let operationOffset: Int
  public let totalInstallations: Int
  public let totalOperations: Int
  public static let pageSize = 25
  public init(_ snapshot: ModelLibrarySnapshot, installationOffset: Int = 0,
    operationOffset: Int = 0) {
    self.installationOffset = max(0, installationOffset)
    self.operationOffset = max(0, operationOffset)
    configuration = snapshot.configuration
    totalInstallations = snapshot.installations.count
    totalOperations = snapshot.operations.count
    installations = Array(snapshot.installations.dropFirst(self.installationOffset)
      .prefix(Self.pageSize)).map(ModelInstallationSummary.init)
    operations = Array(snapshot.operations.dropFirst(self.operationOffset)
      .prefix(Self.pageSize)).map(DownloadOperationSummary.init)
  }
}

public struct ModelRegistry: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public var name: String
  public var provider: ModelProvider
  public var origin: URL
  public var mirror: URL?
  public var credentialReference: String?
  public var mirrorCredentialReference: String?
  public init(id: UUID, name: String, provider: ModelProvider, origin: URL,
    mirror: URL? = nil, credentialReference: String? = nil,
    mirrorCredentialReference: String? = nil
  ) {
    self.id = id; self.name = name; self.provider = provider; self.origin = origin
    self.mirror = mirror; self.credentialReference = credentialReference
    self.mirrorCredentialReference = mirrorCredentialReference
  }
  public func credentialReference(for endpoint: URL) throws -> String? {
    if endpoint == origin { return credentialReference }
    if endpoint == mirror { return mirrorCredentialReference }
    throw MoxError(.busy, "The download endpoint is no longer configured. Restore it or discard the download.")
  }
}
public struct ModelConfiguration: Codable, Sendable, Equatable {
  public enum DefaultProvenance: String, Codable, Sendable { case product, user }
  public var revision: UInt64
  public var defaultRegistryID: UUID
  public var defaultProvenance: DefaultProvenance
  public var registries: [ModelRegistry]
  public func preferredRegistry(for provider: ModelProvider? = nil) -> ModelRegistry? {
    let selected = registries.first { $0.id == defaultRegistryID }
    guard let provider else { return selected }
    if selected?.provider == provider { return selected }
    return registries.first { $0.provider == provider }
  }
  public init(revision: UInt64 = 0, defaultRegistryID: UUID, registries: [ModelRegistry],
    defaultProvenance: DefaultProvenance = .product
  ) {
    self.revision = revision; self.defaultRegistryID = defaultRegistryID
    self.registries = registries; self.defaultProvenance = defaultProvenance
  }
  private enum CodingKeys: String, CodingKey { case revision, defaultRegistryID, registries, defaultProvenance }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    revision = try values.decode(UInt64.self, forKey: .revision)
    defaultRegistryID = try values.decode(UUID.self, forKey: .defaultRegistryID)
    registries = try values.decode([ModelRegistry].self, forKey: .registries)
    defaultProvenance = try values.decodeIfPresent(DefaultProvenance.self, forKey: .defaultProvenance)
      ?? (defaultRegistryID == UUID(uuidString: "2C9C1884-5ED1-4160-B4DC-B89C52C7FE8E")! ? .product : .user)
  }
  public static let defaults = ModelConfiguration(
    defaultRegistryID: UUID(uuidString: "2C9C1884-5ED1-4160-B4DC-B89C52C7FE8E")!, registries: [
      .init(id: UUID(uuidString: "2C9C1884-5ED1-4160-B4DC-B89C52C7FE8E")!, name: "Hugging Face",
        provider: .huggingFace, origin: URL(string: "https://huggingface.co")!),
      .init(id: UUID(uuidString: "8F85D4A6-E720-474F-B522-1EDE81E69204")!, name: "ModelScope",
        provider: .modelScope, origin: URL(string: "https://modelscope.cn")!)])
}
