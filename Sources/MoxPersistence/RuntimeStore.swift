import Foundation
import MoxCore
import MoxDomain
import SwiftData

private enum LegacyRuntimeSchema: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] { [LibraryRecord.self] }
  @Model final class LibraryRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(payload: Data) { key = "library"; self.payload = payload }
  }
}

private enum RuntimeSchema: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)
  static var models: [any PersistentModel.Type] {
    [ConfigurationRecord.self, InstallationRecord.self, OperationRecord.self]
  }
  @Model final class ConfigurationRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(payload: Data) { key = "configuration"; self.payload = payload }
  }
  @Model final class InstallationRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    var orderIndex: Int?
    init(id: String, payload: Data, orderIndex: Int) {
      self.id = id; self.payload = payload; self.orderIndex = orderIndex
    }
  }
  @Model final class OperationRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    var orderIndex: Int?
    init(id: String, payload: Data, orderIndex: Int) {
      self.id = id; self.payload = payload; self.orderIndex = orderIndex
    }
  }
}

/// Service-owned metadata store. A progress update saves only its operation record.
@ModelActor public actor RuntimeStore: ModelLibraryPersistence {
  private var cached: ModelLibrarySnapshot?
  public static func open(root: URL) async throws -> RuntimeStore {
    try await Task.detached {
      let directory = root.appendingPathComponent("runtime")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let schema = Schema(versionedSchema: RuntimeSchema.self)
      let config = ModelConfiguration(schema: schema,
        url: directory.appendingPathComponent("runtime-v2.store"))
      let container = try ModelContainer(for: schema, configurations: [config])
      let store = RuntimeStore(modelContainer: container)
      await store.configure()
      // If an earlier migration failed before save, the missing configuration retries it.
      if try await !store.hasConfiguration(),
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.store").path)
      {
        let oldSchema = Schema(versionedSchema: LegacyRuntimeSchema.self)
        let oldConfig = ModelConfiguration(schema: oldSchema,
          url: directory.appendingPathComponent("runtime.store"))
        let oldContainer = try ModelContainer(for: oldSchema, configurations: [oldConfig])
        let oldContext = ModelContext(oldContainer)
        if let old = try oldContext.fetch(FetchDescriptor<LegacyRuntimeSchema.LibraryRecord>()).first {
          let snapshot = try JSONDecoder().decode(ModelLibrarySnapshot.self, from: old.payload)
          try await store.saveLibrary(snapshot)
        }
      }
      return store
    }.value
  }
  private func configure() { modelContext.autosaveEnabled = false }
  private func hasConfiguration() throws -> Bool {
    try !modelContext.fetch(FetchDescriptor<RuntimeSchema.ConfigurationRecord>()).isEmpty
  }
  public func readLibrary() throws -> ModelLibrarySnapshot {
    if let cached { return cached }
    var snapshot = ModelLibrarySnapshot()
    if let record = try modelContext.fetch(FetchDescriptor<RuntimeSchema.ConfigurationRecord>()).first {
      snapshot.configuration = try JSONDecoder().decode(ModelConfiguration.self, from: record.payload)
    }
    snapshot.installations = try modelContext.fetch(FetchDescriptor<RuntimeSchema.InstallationRecord>())
      .sorted { ($0.orderIndex ?? 0) < ($1.orderIndex ?? 0) }
      .map { try JSONDecoder().decode(ModelInstallation.self, from: $0.payload) }
    snapshot.operations = try modelContext.fetch(FetchDescriptor<RuntimeSchema.OperationRecord>())
      .sorted { ($0.orderIndex ?? 0) < ($1.orderIndex ?? 0) }
      .map { try JSONDecoder().decode(DownloadOperation.self, from: $0.payload) }
    cached = snapshot
    return snapshot
  }
  public func saveLibrary(_ snapshot: ModelLibrarySnapshot) throws {
    do {
      let previous = try readLibrary()
      let encoder = JSONEncoder()
      let configurationExists = try hasConfiguration()
      if previous.configuration != snapshot.configuration || !configurationExists {
        let payload = try encoder.encode(snapshot.configuration)
        if let record = try modelContext.fetch(FetchDescriptor<RuntimeSchema.ConfigurationRecord>()).first {
          record.payload = payload
        } else { modelContext.insert(RuntimeSchema.ConfigurationRecord(payload: payload)) }
      }
      let oldInstallations = Dictionary(uniqueKeysWithValues: previous.installations.map { ($0.id, $0) })
      let newInstallations = Set(snapshot.installations.map(\.id))
      let installationRecords = try modelContext.fetch(FetchDescriptor<RuntimeSchema.InstallationRecord>())
      let installationsByID = Dictionary(uniqueKeysWithValues: installationRecords.map { ($0.id, $0) })
      for (position, item) in snapshot.installations.enumerated() {
        if let record = installationsByID[item.id.uuidString] {
          if oldInstallations[item.id] != item { record.payload = try encoder.encode(item) }
          if record.orderIndex != position { record.orderIndex = position }
        } else {
          modelContext.insert(RuntimeSchema.InstallationRecord(
            id: item.id.uuidString, payload: try encoder.encode(item), orderIndex: position))
        }
      }
      for record in installationRecords where !newInstallations.contains(UUID(uuidString: record.id) ?? UUID()) {
        modelContext.delete(record)
      }
      let oldOperations = Dictionary(uniqueKeysWithValues: previous.operations.map { ($0.id, $0) })
      let newOperations = Set(snapshot.operations.map(\.id))
      let operationRecords = try modelContext.fetch(FetchDescriptor<RuntimeSchema.OperationRecord>())
      let operationsByID = Dictionary(uniqueKeysWithValues: operationRecords.map { ($0.id, $0) })
      for (position, item) in snapshot.operations.enumerated() {
        if let record = operationsByID[item.id.uuidString] {
          if oldOperations[item.id] != item { record.payload = try encoder.encode(item) }
          if record.orderIndex != position { record.orderIndex = position }
        } else {
          modelContext.insert(RuntimeSchema.OperationRecord(
            id: item.id.uuidString, payload: try encoder.encode(item), orderIndex: position))
        }
      }
      for record in operationRecords where !newOperations.contains(UUID(uuidString: record.id) ?? UUID()) {
        modelContext.delete(record)
      }
      try modelContext.save()
      cached = snapshot
    } catch {
      modelContext.rollback()
      cached = nil
      throw MoxError(.storageFailed, "Model library could not be saved; existing data was retained.")
    }
  }
}
