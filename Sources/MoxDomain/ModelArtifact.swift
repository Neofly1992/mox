import Foundation

public enum ModelProvider: String, Codable, Sendable { case huggingFace, modelScope }

/// An access endpoint is deliberately absent: mirrors do not change model identity.
public struct ArtifactOrigin: Codable, Sendable, Hashable {
  public static let aliasPrefix = "mox:"
  public let registryID: UUID
  public let repository: String
  public let revision: String
  public let variant: String
  public init(registryID: UUID, repository: String, revision: String, variant: String = "") {
    self.registryID = registryID
    self.repository = repository
    self.revision = revision
    self.variant = variant
  }
  public var preferredAlias: String {
    "\(Self.aliasPrefix)\(registryID.uuidString):\(repository)#\(variant)"
  }
  public var fixedAlias: String { "\(preferredAlias)@\(revision)" }
}

public enum ArtifactDigest: Codable, Sendable, Equatable {
  case sha256(String)
  case gitBlobSHA1(String)
}

public struct ArtifactFile: Codable, Sendable, Equatable {
  public let path: String
  public let bytes: Int64
  public let digest: ArtifactDigest
  public init(path: String, bytes: Int64, digest: ArtifactDigest) {
    self.path = path
    self.bytes = bytes
    self.digest = digest
  }
}

/// Immutable remote evidence. Local hashes must never be recorded as a remote digest.
public struct ArtifactManifest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let origin: ArtifactOrigin
  public let files: [ArtifactFile]
  public init(origin: ArtifactOrigin, files: [ArtifactFile]) {
    schemaVersion = 1
    self.origin = origin
    self.files = files
  }
}

public struct ModelDownloadPlan: Codable, Sendable {
  public let manifest: ArtifactManifest
  public let totalBytes: Int64
  public let peakBytes: Int64
  public let availableBytes: Int64?
  public init(manifest: ArtifactManifest, totalBytes: Int64, peakBytes: Int64,
    availableBytes: Int64?
  ) {
    self.manifest = manifest
    self.totalBytes = totalBytes
    self.peakBytes = peakBytes
    self.availableBytes = availableBytes
  }
}
public struct ModelDownloadPlanSummary: Codable, Sendable {
  public let origin: ArtifactOrigin
  public let fileCount: Int
  public let totalBytes: Int64
  public let peakBytes: Int64
  public let availableBytes: Int64?
  public init(_ plan: ModelDownloadPlan) {
    origin = plan.manifest.origin; fileCount = plan.manifest.files.count
    totalBytes = plan.totalBytes; peakBytes = plan.peakBytes
    availableBytes = plan.availableBytes
  }
}
