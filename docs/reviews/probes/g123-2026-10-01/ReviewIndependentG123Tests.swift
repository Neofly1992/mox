import Foundation
import MoxDomain
import MoxPersistence
import MoxProtocol
import Testing
@testable import MoxCore

private actor ReviewPendingVerifier: CommittedArtifactVerifying {
 var entered = false
 func inspect(_ origin: ArtifactOrigin, in store: ArtifactStore) async throws -> ArtifactManifest {
  entered = true
  try await Task.sleep(for: .seconds(60))
  return try store.inspectCommitted(origin)
 }
}
@Test func reviewVerificationRequestMustBeVisibleAndCancellable() async throws {
 let root = try temporaryRoot(); let model = try serviceModel()
 defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: model.directory) }
 let store = try await RuntimeStore.open(root: root)
 let artifacts = try ArtifactStore(root: root.appendingPathComponent("models"))
 let item = try committedServiceInstallation(model: model, origin: .init(registryID: UUID(), repository: "fixture/pending", revision: String(repeating: "a", count: 40)), artifacts: artifacts)
 try await store.commit(.init(installations: [item]))
 let verifier = ReviewPendingVerifier()
 let manager = DownloadManager(persistence: store, artifacts: artifacts, verifier: verifier)
 try await withService(downloads: manager) { client, _ in
  let request = try serviceRequest()
  let remote = try client.generate(model: .init(kind: "installedAlias", path: item.alias), request: request)
  let consumer = Task { do { for try await _ in remote.events {} } catch {} }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !(await verifier.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await verifier.entered)
  let state = try await client.state()
  #expect(state.requests.contains { $0.requestID == request.id })
  var cancellationError: String?
  do { _ = try await client.cancel(request.id) } catch { cancellationError = (error as? MoxError)?.code.rawValue ?? "other" }
  #expect(cancellationError == nil)
  await manager.shutdown()
  await consumer.value
 }
}
