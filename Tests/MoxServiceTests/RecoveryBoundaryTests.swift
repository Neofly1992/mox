import Foundation
import MoxCore
import MoxDomain
import MoxPersistence
import MoxProtocol
import Testing

private actor SlowCommittedVerifier: CommittedArtifactVerifying {
  let delay: Duration
  init(delay: Duration = .seconds(60)) { self.delay = delay }
  var entered = false
  var cancelled = false
  func inspect(_ origin: ArtifactOrigin, in store: ArtifactStore) async throws -> ArtifactManifest {
    if origin.repository != "fixture/slow" { return try store.inspectCommitted(origin) }
    entered = true
    do { try await Task.sleep(for: delay) } catch {
      cancelled = true
      throw error
    }
    return try store.inspectCommitted(origin)
  }
}

@Test func recoveringServiceRemainsHealthyPastReadinessAndStopsOwnedWork() async throws {
  let root = try temporaryRoot()
  let model = try serviceModel()
  let healthy = try serviceModel()
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
    try? FileManager.default.removeItem(at: healthy.directory)
  }
  let store = try await RuntimeStore.open(root: root)
  let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
  let item = try committedServiceInstallation(
    model: model,
    origin: .init(
      registryID: UUID(), repository: "fixture/slow", revision: String(repeating: "a", count: 40)),
    artifacts: artifacts)
  try await store.commit(.init(installations: [item]))
  let healthyItem = try committedServiceInstallation(
    model: healthy,
    origin: .init(
      registryID: UUID(), repository: "fixture/healthy", revision: String(repeating: "b", count: 40)
    ), artifacts: artifacts)
  try await store.commit(.init(installations: [healthyItem]))
  let verifier = SlowCommittedVerifier()
  let manager = try await DownloadManager.open(
    persistence: store, artifacts: artifacts, verifier: verifier)
  try await withService(downloads: manager) { client, runtime in
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await verifier.entered), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await verifier.entered)
    let initial = try await client.state()
    #expect(initial.libraryRecovery.phase == .recovering)
    #expect(try await client.library().installations.first?.availability == .checking)
    try await Task.sleep(for: ServiceTiming.readiness + .milliseconds(200))
    _ = try await client.identity()
    #expect(try await client.state().libraryRecovery.phase == .recovering)
    #expect(await runtime.snapshot().activeLeases == 0)
    let blocked = try client.generate(
      model: .init(kind: "installedAlias", path: item.alias), request: serviceRequest())
    let consumer = Task { do { for try await _ in blocked.events {} } catch {} }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await runtime.snapshot().activeLeases == 0)
    // A healthy managed model is verified on demand in the second IO slot.
    let remote = try client.generate(
      model: .init(kind: "installedAlias", path: healthyItem.alias),
      request: serviceRequest())
    for try await _ in remote.events {}
    #expect(await remote.waitUntilStopped())
    #expect(await runtime.snapshot().activeLeases == 0)
    let before = ContinuousClock.now
    await manager.shutdown()
    #expect(ContinuousClock.now - before < .seconds(2))
    #expect(await verifier.cancelled)
    await consumer.value
  }
}

@Test func uuidAliasAndIDUseOneUnambiguousNamespace() async throws {
  let root = try temporaryRoot()
  let first = try serviceModel()
  let second = try serviceModel()
  defer {
    for url in [root, first.directory, second.directory] {
      try? FileManager.default.removeItem(at: url)
    }
  }
  let store = try await RuntimeStore.open(root: root)
  let manager = try await DownloadManager.open(
    persistence: store, artifacts: ArtifactStore(root: root.appendingPathComponent("models")))
  await manager.waitForRecovery()
  try await withService(downloads: manager) { client, _ in
    let alias = "abcdefab-cdef-abcd-efab-cdefabcdefab"
    let item = try await client.importModel(path: first.directory.path, alias: alias)
    for identifier in [alias, alias.uppercased(), item.id.uuidString] {
      _ = try await client.resolveSampling(
        .init(model: .init(kind: "installedAlias", path: identifier)))
    }
    await #expect(throws: MoxError.self) {
      _ = try await client.importModel(path: second.directory.path, alias: item.id.uuidString)
    }
    let conflict = ModelInstallation(
      id: UUID(uuidString: alias)!, path: second.directory.path, manifest: nil, alias: "other")
    try await store.commit(.init(installations: [conflict]))
    await #expect(throws: MoxError.self) {
      _ = try await client.resolveSampling(
        .init(model: .init(kind: "installedAlias", path: alias)))
    }
  }
}

@Test func verificationPreservesSettingsSavedWhileHashing() async throws {
  let root = try temporaryRoot()
  let model = try serviceModel()
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: model.directory)
  }
  let store = try await RuntimeStore.open(root: root)
  let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
  let item = try committedServiceInstallation(
    model: model,
    origin: .init(
      registryID: UUID(), repository: "fixture/slow", revision: String(repeating: "a", count: 40)),
    artifacts: artifacts)
  try await store.commit(.init(installations: [item]))
  let verifier = SlowCommittedVerifier(delay: .seconds(1))
  let manager = try await DownloadManager.open(
    persistence: store, artifacts: artifacts, verifier: verifier)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !(await verifier.entered), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  let revision = try await manager.configuration().revision
  _ = try await manager.setModelSampling(
    item.id, settings: .init(maxTokens: 123), expectedRevision: revision)
  await manager.waitForRecovery()
  let current = try await manager.installation(item.id)
  #expect(current.availability == .ready)
  #expect(current.samplingSettings.maxTokens == 123)
  await manager.shutdown()
}
