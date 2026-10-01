import Foundation
import MoxCore
import MoxDomain
import SwiftData

enum RuntimeSchema: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)
  static var models: [any PersistentModel.Type] {
    [ConfigurationRecord.self, InstallationRecord.self, OperationRecord.self]
  }
  @Model final class ConfigurationRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(payload: Data) {
      key = "configuration"
      self.payload = payload
    }
  }
  @Model final class InstallationRecord {
    #Index<InstallationRecord>(
      [\.aliasKey], [\.path], [\.originKey], [\.familyKey], [\.orderIndex, \.id])
    @Attribute(.unique) var id: String
    var payload: Data
    var summaryPayload: Data?
    var orderIndex: Int?
    var aliasKey: String?
    var path: String?
    var originKey: String?
    var familyKey: String?
    init(id: String, payload: Data, orderIndex: Int) {
      self.id = id
      self.payload = payload
      self.orderIndex = orderIndex
    }
  }
  @Model final class OperationRecord {
    #Index<OperationRecord>([\.originKey], [\.active], [\.orderIndex, \.id])
    @Attribute(.unique) var id: String
    var payload: Data
    var summaryPayload: Data?
    var orderIndex: Int?
    var originKey: String?
    var phase: String?
    var active: Bool?
    var blocksCreation: Bool?
    init(id: String, payload: Data, orderIndex: Int) {
      self.id = id
      self.payload = payload
      self.orderIndex = orderIndex
    }
  }
}

/// Identity mutations and storage pagination; no full-library cache or diff.
@ModelActor public actor RuntimeStore: ModelLibraryPersistence {
  public static func open(root: URL) async throws -> RuntimeStore {
    try await Task.detached {
      let directory = root.appendingPathComponent("runtime")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let schema = Schema(versionedSchema: RuntimeSchema.self)
      let config = SwiftData.ModelConfiguration(
        schema: schema, url: directory.appendingPathComponent("runtime-v2.store"))
      let store = RuntimeStore(
        modelContainer: try ModelContainer(for: schema, configurations: [config]))
      try await store.configure()
      return store
    }.value
  }
  private func configure() throws {
    modelContext.autosaveEnabled = false
    // Query projections are rebuildable indexes, never another business authority.
    // Rebuild missing projections in bounded batches, preserving each payload.
    while true {
      var query = FetchDescriptor<RuntimeSchema.InstallationRecord>(
        predicate: #Predicate { $0.summaryPayload == nil || $0.aliasKey == nil })
      query.fetchLimit = 1
      let records = try modelContext.fetch(query)
      if records.isEmpty { break }
      for record in records { try project(record, decode(ModelInstallation.self, record.payload)) }
      try modelContext.save()
    }
    while true {
      var query = FetchDescriptor<RuntimeSchema.OperationRecord>(
        predicate: #Predicate { $0.summaryPayload == nil })
      query.fetchLimit = 1
      let records = try modelContext.fetch(query)
      if records.isEmpty { break }
      for record in records { try project(record, decode(DownloadOperation.self, record.payload)) }
      try modelContext.save()
    }
  }
  private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw MoxError(
        .storageFailed, "Model metadata could not be read; existing data was retained.")
    }
  }
  private func project(_ record: RuntimeSchema.InstallationRecord, _ item: ModelInstallation) throws
  {
    record.summaryPayload = try JSONEncoder().encode(ModelInstallationSummary(item))
    record.aliasKey = ModelIdentifier.aliasKey(item.alias)
    record.path = item.path
    record.familyKey = item.manifest?.origin.preferredAlias ?? ""
    record.originKey = try item.manifest.map { try ArtifactValidation.identifier(for: $0.origin) }
  }
  private func project(_ record: RuntimeSchema.OperationRecord, _ item: DownloadOperation) throws {
    record.summaryPayload = try JSONEncoder().encode(DownloadOperationSummary(item))
    record.originKey = try ArtifactValidation.identifier(for: item.manifest.origin)
    record.phase = item.phase.rawValue
    record.active = item.phase.isActive
    record.blocksCreation = item.phase != .cancelled && item.phase != .failed
  }
  public func configuration() throws -> MoxDomain.ModelConfiguration {
    var query = FetchDescriptor<RuntimeSchema.ConfigurationRecord>()
    query.fetchLimit = 1
    guard let record = try modelContext.fetch(query).first else { return .defaults }
    return try decode(MoxDomain.ModelConfiguration.self, record.payload)
  }
  public func installation(_ lookup: InstallationLookup) throws -> ModelInstallation? {
    let predicate: Predicate<RuntimeSchema.InstallationRecord>
    switch lookup {
    case .id(let id):
      let key = id.uuidString
      predicate = #Predicate { $0.id == key }
    case .alias(let alias):
      let key = ModelIdentifier.aliasKey(alias)
      predicate = #Predicate { $0.aliasKey == key }
    case .path(let path): predicate = #Predicate { $0.path == path }
    case .origin(let origin):
      let key = try ArtifactValidation.identifier(for: origin)
      predicate = #Predicate { $0.originKey == key }
    }
    var query = FetchDescriptor(predicate: predicate)
    query.fetchLimit = 1
    return try modelContext.fetch(query).first.map {
      try decode(ModelInstallation.self, $0.payload)
    }
  }
  public func operation(_ id: UUID) throws -> DownloadOperation? {
    let key = id.uuidString
    var query = FetchDescriptor<RuntimeSchema.OperationRecord>(
      predicate: #Predicate { $0.id == key })
    query.fetchLimit = 1
    return try modelContext.fetch(query).first.map {
      try decode(DownloadOperation.self, $0.payload)
    }
  }
  public func installations(offset: Int, limit: Int) throws -> [ModelInstallation] {
    var query = FetchDescriptor<RuntimeSchema.InstallationRecord>(sortBy: [
      SortDescriptor(\.orderIndex), SortDescriptor(\.id),
    ])
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map { try decode(ModelInstallation.self, $0.payload) }
  }
  public func operations(offset: Int, limit: Int) throws -> [DownloadOperation] {
    var query = FetchDescriptor<RuntimeSchema.OperationRecord>(sortBy: [
      SortDescriptor(\.orderIndex), SortDescriptor(\.id),
    ])
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map { try decode(DownloadOperation.self, $0.payload) }
  }
  public func operations(origin: ArtifactOrigin, offset: Int, limit: Int) throws
    -> [DownloadOperation]
  {
    let key = try ArtifactValidation.identifier(for: origin)
    var query = FetchDescriptor<RuntimeSchema.OperationRecord>(
      predicate: #Predicate { $0.originKey == key },
      sortBy: [SortDescriptor(\.orderIndex), SortDescriptor(\.id)])
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map { try decode(DownloadOperation.self, $0.payload) }
  }
  public func hasUnfinishedOperation(origin: ArtifactOrigin) throws -> Bool {
    let key = try ArtifactValidation.identifier(for: origin)
    let query = FetchDescriptor<RuntimeSchema.OperationRecord>(
      predicate: #Predicate { $0.originKey == key && $0.blocksCreation == true })
    return try modelContext.fetchCount(query) > 0
  }
  public func relatedInstallations(origin: ArtifactOrigin, offset: Int, limit: Int) throws
    -> [ModelInstallation]
  {
    let family = origin.preferredAlias
    var query = FetchDescriptor<RuntimeSchema.InstallationRecord>(
      predicate: #Predicate { $0.familyKey == family },
      sortBy: [SortDescriptor(\.orderIndex), SortDescriptor(\.id)])
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map { try decode(ModelInstallation.self, $0.payload) }
  }
  public func installationSummaries(offset: Int, limit: Int) throws -> [ModelInstallationSummary] {
    var query = FetchDescriptor<RuntimeSchema.InstallationRecord>(sortBy: [
      SortDescriptor(\.orderIndex), SortDescriptor(\.id),
    ])
    query.propertiesToFetch = [\.summaryPayload]
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map {
      guard let payload = $0.summaryPayload else {
        throw MoxError(.storageFailed, "Model summary is unavailable.")
      }
      return try decode(ModelInstallationSummary.self, payload)
    }
  }
  public func operationSummaries(offset: Int, limit: Int) throws -> [DownloadOperationSummary] {
    var query = FetchDescriptor<RuntimeSchema.OperationRecord>(sortBy: [
      SortDescriptor(\.orderIndex), SortDescriptor(\.id),
    ])
    query.propertiesToFetch = [\.summaryPayload]
    query.fetchOffset = max(0, offset)
    query.fetchLimit = min(100, max(1, limit))
    return try modelContext.fetch(query).map {
      guard let payload = $0.summaryPayload else {
        throw MoxError(.storageFailed, "Download summary is unavailable.")
      }
      return try decode(DownloadOperationSummary.self, payload)
    }
  }
  public func installationCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<RuntimeSchema.InstallationRecord>())
  }
  public func operationCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<RuntimeSchema.OperationRecord>())
  }
  public func activeOperationCount() throws -> Int {
    let query = FetchDescriptor<RuntimeSchema.OperationRecord>(
      predicate: #Predicate { $0.active == true })
    return try modelContext.fetchCount(query)
  }
  public func commit(_ changes: LibraryChanges) throws {
    do {
      let encoder = JSONEncoder()
      if let configuration = changes.configuration {
        var query = FetchDescriptor<RuntimeSchema.ConfigurationRecord>()
        query.fetchLimit = 1
        if let record = try modelContext.fetch(query).first {
          record.payload = try encoder.encode(configuration)
        } else {
          modelContext.insert(
            RuntimeSchema.ConfigurationRecord(payload: try encoder.encode(configuration)))
        }
      }
      for item in changes.installations {
        let key = item.id.uuidString
        var query = FetchDescriptor<RuntimeSchema.InstallationRecord>(
          predicate: #Predicate { $0.id == key })
        query.fetchLimit = 1
        let record: RuntimeSchema.InstallationRecord
        if let existing = try modelContext.fetch(query).first {
          record = existing
          record.payload = try encoder.encode(item)
        } else {
          var last = FetchDescriptor<RuntimeSchema.InstallationRecord>(sortBy: [
            SortDescriptor(\.orderIndex, order: .reverse)
          ])
          last.fetchLimit = 1
          let position = (try modelContext.fetch(last).first?.orderIndex ?? -1) + 1
          record = .init(id: key, payload: try encoder.encode(item), orderIndex: position)
          modelContext.insert(record)
        }
        try project(record, item)
      }
      for item in changes.operations {
        let key = item.id.uuidString
        var query = FetchDescriptor<RuntimeSchema.OperationRecord>(
          predicate: #Predicate { $0.id == key })
        query.fetchLimit = 1
        let record: RuntimeSchema.OperationRecord
        if let existing = try modelContext.fetch(query).first {
          record = existing
          record.payload = try encoder.encode(item)
        } else {
          var last = FetchDescriptor<RuntimeSchema.OperationRecord>(sortBy: [
            SortDescriptor(\.orderIndex, order: .reverse)
          ])
          last.fetchLimit = 1
          let position = (try modelContext.fetch(last).first?.orderIndex ?? -1) + 1
          record = .init(id: key, payload: try encoder.encode(item), orderIndex: position)
          modelContext.insert(record)
        }
        try project(record, item)
      }
      for id in changes.removedInstallations {
        let key = id.uuidString
        let query = FetchDescriptor<RuntimeSchema.InstallationRecord>(
          predicate: #Predicate { $0.id == key })
        for record in try modelContext.fetch(query) { modelContext.delete(record) }
      }
      for id in changes.removedOperations {
        let key = id.uuidString
        let query = FetchDescriptor<RuntimeSchema.OperationRecord>(
          predicate: #Predicate { $0.id == key })
        for record in try modelContext.fetch(query) { modelContext.delete(record) }
      }
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw MoxError(
        .storageFailed, "Model metadata could not be saved; existing data was retained.")
    }
  }
}
