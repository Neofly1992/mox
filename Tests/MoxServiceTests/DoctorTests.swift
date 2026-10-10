import Darwin
import Foundation
import MoxBootstrap
import MoxClient
import MoxCore
import MoxDomain
import MoxPersistence
import MoxProtocol
import Testing

@Test func doctorPartialFailureTimeoutCancellationAndRedaction() async throws {
  let checks: [DoctorCheck] = [
    .init(id: "failure") {
      throw NSError(
        domain: "PRIVATE-token", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "SECRET /private/path prompt"])
    },
    .init(id: "slow") {
      try await Task.sleep(for: .seconds(1))
      return .init(id: "slow", status: .passed, reason: "Should not pass")
    },
    .init(id: "last") { .init(id: "last", status: .passed, reason: "Still runs") },
  ]
  let report = await DoctorRunner.run(checks, timeout: .milliseconds(20))
  #expect(report.results.map(\.status) == [.failed, .timedOut, .passed])
  #expect(report.exitCode == 1)
  let data = String(decoding: try Wire.encode(report), as: UTF8.self)
  #expect(
    !data.contains("SECRET") && !data.contains("PRIVATE-token") && !data.contains("/private/path"))
  #expect(report.events.first?.systemCode == 13)
  let cancelled = Task { await DoctorRunner.run(checks.reversed()) }
  cancelled.cancel()
  #expect(await cancelled.value.exitCode == 130)
}

@Test func doctorOfflineDoesNotCreateDirectoriesOrRequireDevelopmentTools() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "missing-doctor-\(UUID())")
  let report = await DoctorRunner.run(
    DoctorChecks.local(root: root.path, worker: URL(fileURLWithPath: "/missing-worker")))
  #expect(!FileManager.default.fileExists(atPath: root.path))
  #expect(report.results.first(where: { $0.id == "service.identity" })?.status == .skipped)
  #expect(report.results.first(where: { $0.id == "package.resources" })?.status == .failed)
  #expect(report.results.first(where: { $0.id == "environment.runtime" })?.status == .passed)
}

@Test func doctorUnsafePermissionsAndVersionMismatchKeepOtherChecks() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  var identity = ServiceIdentity(
    pid: 123, uid: getuid(), rootIdentity: files.rootIdentity, ownership: .foreground)
  identity.buildID = "different-build"
  try files.publish(
    .init(
      identity: identity, privateEndpoint: "http://127.0.0.1:1",
      token: String(repeating: "a", count: 64)))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.run.path)
  let report = await DoctorRunner.run(
    DoctorChecks.local(root: root.path, worker: URL(fileURLWithPath: "/missing")))
  #expect(report.results.first(where: { $0.id == "data.permissions" })?.status == .failed)
  #expect(report.results.first(where: { $0.id == "service.identity" })?.status == .failed)
  #expect(report.results.first(where: { $0.id == "data.disk" })?.status == .passed)
  #expect(report.events.contains(where: { $0.code == "incompatibleService" }))
}

@Test func resourcePreviewAndReadOnlyIntegrityUseRealHTTP() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService { client, runtime in
    let reference = GenerateBody.Model(kind: "localDirectory", path: model.directory.path)
    let small = try await client.assessResources(
      .init(model: reference, explicit: .init(maxTokens: 1)))
    let large = try await client.assessResources(
      .init(model: reference, explicit: .init(maxTokens: 8192)))
    #expect(small.status == .recommended)
    #expect(large.kvBytes! > small.kvBytes!)
    #expect(try await client.inspectModel(reference).status == .passed)
    #expect(await runtime.snapshot().residentModels == 0)
    await runtime.updatePressure(.warning)
    #expect(try await client.state().admissionPaused)
  }
}

@Test func doctorCancelledBeforeRequestArrivalCannotStartInspection() async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  try await withService { client, runtime in
    let id = UUID()
    let (_, cancelResponse) = try await URLSession.shared.data(
      for: client.request("/doctor/\(id)/cancel", method: "POST"))
    #expect((cancelResponse as? HTTPURLResponse)?.statusCode == 200)
    let body = DoctorInspectionBody(
      requestID: id, model: .init(kind: "localDirectory", path: model.directory.path))
    let (_, inspectResponse) = try await URLSession.shared.data(
      for: client.request("/doctor/inspect", method: "POST", body: Wire.encode(body)))
    #expect((inspectResponse as? HTTPURLResponse)?.statusCode != 200)
    #expect(await runtime.snapshot().residentModels == 0)
  }
}

private actor DiagnosticSourceProbe: ResolvedModelSource {
  var entered = false
  var stopped = false
  var starts = 0
  func resolve(registryID: UUID, repository: String, selector: String, variant: String) async throws
    -> ArtifactManifest
  {
    entered = true
    starts += 1
    stopped = false
    defer { stopped = true }
    try await Task.sleep(for: .seconds(60))
    throw MoxError(.invalidModel, "Probe should have been cancelled.")
  }
  func download(_ file: ArtifactFile, manifest: ArtifactManifest, to root: URL) async throws {
    Issue.record("Doctor must never download weights")
  }
}
private struct DiagnosticSourceFactory: ModelSourceFactory {
  let source: DiagnosticSourceProbe
  func make(provider: ModelProvider, endpoint: URL, credentialReference: String?) throws
    -> any ResolvedModelSource
  { source }
  func saveCredential(_ value: String, registryID: UUID, endpoint: URL) throws -> String {
    throw MoxError(.invalidParameters, "No credential mutations in doctor")
  }
  func deleteCredential(reference: String) throws {
    Issue.record("No credential mutations in doctor")
  }
}
@Test func doctorDeadlineCancelsAndWaitsForServiceOwnedSourceInspection() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await MoxPersistence.RuntimeStore.open(root: root)
  let downloads = try await MoxCore.DownloadManager.open(
    persistence: store,
    artifacts: MoxCore.ArtifactStore(root: root.appendingPathComponent("models")))
  let probe = DiagnosticSourceProbe()
  try await withService(downloads: downloads, sources: DiagnosticSourceFactory(source: probe)) {
    client, _ in
    let config = try await client.library().configuration
    let registry = try #require(config.preferredRegistry(for: nil))
    let body = PullBody(
      provider: registry.provider, endpoint: registry.mirror ?? registry.origin,
      registryID: registry.id, repository: "owner/model", selector: "main", variant: "")
    let check = DoctorCheck(id: "source.connectivity") { try await client.inspectSource(body) }
    let report = await DoctorRunner.run([check], timeout: .milliseconds(300))
    #expect(report.results.first?.status == .timedOut)
    #expect(report.results.first?.reason == "Check deadline exceeded.")
    #expect(await probe.entered)
    #expect(await probe.stopped)
    #expect(try await downloads.activeOperationCount() == 0)
    let cancellation = Task { await DoctorRunner.run([check]) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await probe.starts < 2, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await probe.starts == 2)
    cancellation.cancel()
    let cancelled = await cancellation.value
    #expect(cancelled.results.first?.status == .cancelled)
    #expect(cancelled.results.first?.reason == "Check cancelled.")
    #expect(await probe.stopped)
  }
}

@Test func doctorOwnerOnlyButUnusableRuntimeDirectoryFails() async throws {
  let root = try temporaryRoot()
  let files = try ServiceFiles(path: root.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.run.path)
    try? FileManager.default.removeItem(at: root)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.run.path)
  let check = try #require(DoctorChecks.local(root: root.path, worker: URL(fileURLWithPath: "/missing"))
    .first { $0.id == "data.permissions" })
  let result = try await check.operation()
  #expect(result.status == .failed)
  #expect(result.reason.contains("cannot be read, written or traversed"))
  let attributes = try FileManager.default.attributesOfItem(atPath: files.run.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o500)
}

@Test func doctorRejectsDiscoveryPipeAndKeepsRemainingChecksBounded() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try ServiceFiles(path: root.path)
  let path = files.run.appendingPathComponent("discovery.json").path
  #expect(mkfifo(path, 0o600) == 0)
  let checks = DoctorChecks.local(root: root.path, worker: URL(fileURLWithPath: "/missing"))
  let identity = try #require(checks.first { $0.id == "service.identity" })
  let start = ContinuousClock.now
  let report = await DoctorRunner.run([identity,
    .init(id: "last") { .init(id: "last", status: .passed, reason: "Still runs") }], timeout: .seconds(1))
  #expect(start.duration(to: .now) < .seconds(2))
  #expect(report.results.map(\.status) == [.failed, .passed])
  #expect(report.events.first?.code == "serviceConflict")
  let cancelled = Task { await DoctorRunner.run([identity], timeout: .seconds(1)) }
  cancelled.cancel()
  #expect(await cancelled.value.exitCode == 130)
  var metadata = stat()
  #expect(lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFIFO)
}

@Test(arguments: ["model.safetensors", "config.json", "tokenizer.json"])
func exceptionalModelFilesDoNotBlockPreviewSamplingOrServiceShutdown(file: String) async throws {
  let model = try serviceModel()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let path = model.directory.appendingPathComponent(file).path
  try FileManager.default.removeItem(atPath: path)
  #expect(mkfifo(path, 0o600) == 0)
  try await withService { client, runtime in
    let reference = GenerateBody.Model(kind: "localDirectory", path: model.directory.path)
    let check = DoctorCheck(id: "preview") {
      let result = try await client.assessResources(.init(model: reference))
      #expect(result.status == .unknown)
      return .init(id: "preview", status: .passed, reason: "Unsupported file rejected")
    }
    let report = await DoctorRunner.run([check], timeout: .seconds(5))
    #expect(report.results.first?.status == .passed, "Preview result: \(report.results)")
    let sampling = try await client.resolveSampling(.init(model: reference))
    #expect(sampling.maxTokens > 0)
    let integrity = await DoctorRunner.run([
      .init(id: "model.integrity") { try await client.inspectModel(reference) }
    ], timeout: .seconds(1))
    #expect(integrity.results.first?.status == .failed)
    #expect(await runtime.snapshot().residentModels == 0)
  }
}
