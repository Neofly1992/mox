import Foundation
import MoxDomain

/// Hashing runs outside the library actor, with cancellation propagated to IO.
public protocol CommittedArtifactVerifying: Sendable {
  func inspect(_ origin: ArtifactOrigin, in store: ArtifactStore) async throws -> ArtifactManifest
}
public struct CommittedArtifactVerifier: CommittedArtifactVerifying {
  public init() {}
  public func inspect(_ origin: ArtifactOrigin, in store: ArtifactStore) async throws
    -> ArtifactManifest
  {
    let task = Task.detached { try store.inspectCommitted(origin) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
