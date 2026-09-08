import Foundation
import MoxDomain
import Testing

@testable import MoxCore

private struct Key: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
@Test func diagnosticsClassifyAndRedact() {
  let secret = "private-prompt-token-path"
  let context = DecodingError.Context(
    codingPath: [Key("quantization"), Key(secret)], debugDescription: secret)
  let missing = BackendFailure(DecodingError.keyNotFound(Key("bits"), context), stage: .load)
  let mismatch = BackendFailure(DecodingError.typeMismatch(Int.self, context), stage: .load)
  #expect(missing.category == "keyNotFound")
  #expect(mismatch.category == "typeMismatch")
  #expect(missing.codingPath == "quantization.<redacted>.bits")
  #expect(!String(reflecting: missing).contains(secret))
  let underlying = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
  let failure = BackendFailure(underlying, stage: .prepare)
  #expect(failure.domain == "redacted" && failure.code == 42)
  #expect(failure.clientError.code == .generationFailed)
  #expect(!String(reflecting: failure).contains(secret))
  let preserved = BackendFailure(missing, stage: .generate)
  #expect(preserved.stage == .load && preserved.codingPath == missing.codingPath)
  let posix = BackendFailure(NSError(domain: NSPOSIXErrorDomain, code: 13), stage: .load)
  #expect(posix.domain == NSPOSIXErrorDomain && posix.code == 13)
}

private struct FailingBackend: RuntimeBackend {
  let duringLoad: Bool
  func load(_ model: LocalModel) async throws -> any LoadedModel {
    if duringLoad {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: 13,
        userInfo: [NSLocalizedDescriptionKey: "private-load-prompt"])
    }
    return FailingLoaded()
  }
}
private struct FailingLoaded: LoadedModel {
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  {
    throw BackendFailure(
      DecodingError.keyNotFound(
        Key("chat_template"), .init(codingPath: [], debugDescription: "private-generation-prompt")),
      stage: .prepare)
  }
  func unload() async {}
}
@Test func diagnosticsSurviveCoordinatorBoundary() async throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  for duringLoad in [true, false] {
    let core = RuntimeCoordinator(
      backend: FailingBackend(duringLoad: duringLoad), policy: .init(budgetBytes: 512 * 1024 * 1024)
    )
    let events = await collect(try await core.generate(model: model, request: request()))
    if case .failed(let error) = events.last?.payload {
      #expect(error.code == (duringLoad ? .loadFailed : .generationFailed))
      #expect(!error.description.contains("private-"))
    } else {
      Issue.record("Expected a stable client failure")
    }
    #expect(await core.snapshot().activeLeases == 0)
    await core.shutdown()
    #expect(await core.snapshot().reservedBytes == 0)
  }
}
