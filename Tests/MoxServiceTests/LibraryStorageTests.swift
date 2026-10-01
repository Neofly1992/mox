import Foundation
import MoxCore
import MoxDomain
import SwiftData
import Testing

@testable import MoxPersistence

extension RuntimeStore {
  fileprivate func corruptInstallationPayload(_ id: UUID) throws {
    let key = id.uuidString
    let query = FetchDescriptor<RuntimeSchema.InstallationRecord>(
      predicate: #Predicate { $0.id == key })
    let record = try #require(modelContext.fetch(query).first)
    record.payload = Data("broken-record".utf8)
    try modelContext.save()
  }
}
@Test func identityAndSummaryQueriesDoNotDecodeUnrelatedCatalogPayloads() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let healthy = ModelInstallation(path: "/tmp/healthy", manifest: nil, alias: "healthy")
  let damaged = ModelInstallation(path: "/tmp/damaged", manifest: nil, alias: "damaged")
  try await store.commit(.init(installations: [healthy, damaged]))
  try await store.corruptInstallationPayload(damaged.id)
  #expect(try await store.installation(.id(healthy.id))?.alias == "healthy")
  var configuration = try await store.configuration()
  configuration.revision += 1
  var changed = healthy
  changed.samplingSettings = .init(maxTokens: 30)
  try await store.commit(.init(configuration: configuration, installations: [changed]))
  #expect(
    try await store.installationSummaries(offset: 0, limit: 1).first?.samplingSettings.maxTokens
      == 30)
  #expect(try await store.installationSummaries(offset: 1, limit: 1).first?.id == damaged.id)
  await #expect(throws: MoxError.self) { _ = try await store.installation(.id(damaged.id)) }
  let reopened = try await RuntimeStore.open(root: root)
  #expect(try await reopened.configuration().revision == 1)
  #expect(try await reopened.installation(.id(healthy.id))?.samplingSettings.maxTokens == 30)
}
@Test func storagePagesAndIdentityUpdatesPreserveOtherRows() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await RuntimeStore.open(root: root)
  let items = (0..<61).map {
    ModelInstallation(path: "/tmp/model-\($0)", manifest: nil, alias: "model-\($0)")
  }
  try await store.commit(.init(installations: items))
  #expect(
    try await store.installationSummaries(offset: 25, limit: 25).map(\.id)
      == Array(items[25..<50]).map(\.id))
  var changed = items[30]
  changed.pinned = true
  try await store.commit(.init(installations: [changed], removedInstallations: [items[0].id]))
  let reopened = try await RuntimeStore.open(root: root)
  #expect(try await reopened.installationCount() == 60)
  #expect(try await reopened.installation(.id(items[30].id))?.pinned == true)
  #expect(try await reopened.installation(.alias(items[60].alias))?.id == items[60].id)
  #expect(
    try await reopened.installationSummaries(offset: 50, limit: 25).map(\.id)
      == Array(items[51..<61]).map(\.id))
}
