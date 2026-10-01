import Foundation
import MoxDomain

@testable import MoxCore

protocol SnapshotTestPersistence: ModelLibraryPersistence {
  func readLibrary() async throws -> ModelLibrarySnapshot
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) async throws
}
extension SnapshotTestPersistence {
  func configuration() async throws -> ModelConfiguration { try await readLibrary().configuration }
  func installation(_ lookup: InstallationLookup) async throws -> ModelInstallation? {
    try await readLibrary().installations.first {
      switch lookup {
      case .id(let id): $0.id == id
      case .alias(let alias): ModelIdentifier.aliasKey($0.alias) == ModelIdentifier.aliasKey(alias)
      case .path(let path): $0.path == path
      case .origin(let origin): $0.manifest?.origin == origin
      }
    }
  }
  func operation(_ id: UUID) async throws -> DownloadOperation? {
    try await readLibrary().operations.first { $0.id == id }
  }
  func installations(offset: Int, limit: Int) async throws -> [ModelInstallation] {
    Array(try await readLibrary().installations.dropFirst(offset).prefix(limit))
  }
  func operations(offset: Int, limit: Int) async throws -> [DownloadOperation] {
    Array(try await readLibrary().operations.dropFirst(offset).prefix(limit))
  }
  func operations(origin: ArtifactOrigin, offset: Int, limit: Int) async throws
    -> [DownloadOperation]
  {
    Array(
      try await readLibrary().operations.filter { $0.manifest.origin == origin }.dropFirst(offset)
        .prefix(limit))
  }
  func hasUnfinishedOperation(origin: ArtifactOrigin) async throws -> Bool {
    try await readLibrary().operations.contains {
      $0.manifest.origin == origin && $0.phase != .cancelled && $0.phase != .failed
    }
  }
  func relatedInstallations(origin: ArtifactOrigin, offset: Int, limit: Int) async throws
    -> [ModelInstallation]
  {
    Array(
      try await readLibrary().installations.filter {
        $0.manifest?.origin.preferredAlias == origin.preferredAlias
      }.dropFirst(offset).prefix(limit))
  }
  func installationSummaries(offset: Int, limit: Int) async throws -> [ModelInstallationSummary] {
    try await installations(offset: offset, limit: limit).map(ModelInstallationSummary.init)
  }
  func operationSummaries(offset: Int, limit: Int) async throws -> [DownloadOperationSummary] {
    try await operations(offset: offset, limit: limit).map(DownloadOperationSummary.init)
  }
  func installationCount() async throws -> Int { try await readLibrary().installations.count }
  func operationCount() async throws -> Int { try await readLibrary().operations.count }
  func activeOperationCount() async throws -> Int {
    try await readLibrary().operations.filter { $0.phase.isActive }.count
  }
  func commit(_ changes: LibraryChanges) async throws {
    var snapshot = try await readLibrary()
    if let configuration = changes.configuration { snapshot.configuration = configuration }
    for item in changes.installations {
      if let index = snapshot.installations.firstIndex(where: { $0.id == item.id }) {
        snapshot.installations[index] = item
      } else {
        snapshot.installations.append(item)
      }
    }
    for item in changes.operations {
      if let index = snapshot.operations.firstIndex(where: { $0.id == item.id }) {
        snapshot.operations[index] = item
      } else {
        snapshot.operations.append(item)
      }
    }
    snapshot.installations.removeAll { changes.removedInstallations.contains($0.id) }
    snapshot.operations.removeAll { changes.removedOperations.contains($0.id) }
    try await saveLibrary(snapshot)
  }
}
extension DownloadManager {
  func snapshot() async throws -> ModelLibrarySnapshot {
    var result = ModelLibrarySnapshot()
    result.configuration = try await configuration()
    var offset = 0
    while true {
      let page = try await installations(offset: offset)
      result.installations += page
      if page.count < 100 { break }
      offset += page.count
    }
    offset = 0
    while true {
      let page = try await operations(offset: offset)
      result.operations += page
      if page.count < 100 { break }
      offset += page.count
    }
    return result
  }
}

extension ArtifactStore {
  func committedManifests() throws -> [ArtifactManifest] {
    try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("artifacts"), includingPropertiesForKeys: nil
    )
    .map { try inspectCommittedDirectory($0) }
  }
}
