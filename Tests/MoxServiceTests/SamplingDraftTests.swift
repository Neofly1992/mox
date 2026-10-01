import Foundation
import MoxChat
import MoxDomain
import Testing

@Test @MainActor func samplingDraftSurvivesFailureAndCanRetry() async {
  let draft = SamplingSettingsDraft(.init(maxTokens: 77, temperature: 0.3))
  draft.topP = "0.8"
  let failed = await draft.save { _ in
    throw MoxError(.storageFailed, "Settings could not be saved.")
  }
  #expect(!failed)
  #expect(draft.maxTokens == "77" && draft.temperature == "0.3" && draft.topP == "0.8")
  #expect(draft.error != nil && !draft.saving)
  let saved = await draft.save { settings in
    #expect(settings.maxTokens == 77 && settings.topP == 0.8)
  }
  #expect(saved && draft.error == nil && !draft.saving)
}
@Test @MainActor func samplingDraftRejectsDuplicateSubmitWithoutDiscardingInput() async {
  let draft = SamplingSettingsDraft(.init(maxTokens: 45))
  var continuation: CheckedContinuation<Void, Never>?
  let first = Task { @MainActor in
    await draft.save { _ in
      await withCheckedContinuation { continuation = $0 }
    }
  }
  while !draft.saving { await Task.yield() }
  var duplicateCalled = false
  let duplicate = await draft.save { _ in duplicateCalled = true }
  #expect(!duplicate && !duplicateCalled && draft.saving)
  #expect(draft.maxTokens == "45")
  continuation?.resume()
  #expect(await first.value)
}
