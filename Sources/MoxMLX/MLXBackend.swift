import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Metal
import MoxCore
import MoxDomain
import OSLog

public struct MLXBackend: RuntimeBackend {
  /// Composition creates one MLX backend per process. Limits are configured once,
  /// never changed by individual requests. Coordinator remains admission authority.
  public init(memoryLimit: Int) {
    Memory.memoryLimit = memoryLimit
    Memory.cacheLimit = 64 * 1024 * 1024
  }
  public static func recommendedBudget() throws -> Int {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw MoxError(.resourceLimit, "A Metal device is required.")
    }
    let physical = ProcessInfo.processInfo.physicalMemory
    // Leave at least 35% of RAM to macOS/other applications and headroom below Metal's recommendation.
    let budget = min(Double(physical) * 0.65, Double(device.recommendedMaxWorkingSetSize) * 0.8)
    return Int(budget)
  }
  public func load(_ model: LocalModel) async throws -> any LoadedModel {
    var stage = BackendFailure.Stage.load
    do {
      let container = try await LLMModelFactory.shared.loadContainer(
        from: model.directory, using: LocalTokenizerLoader())
      stage = .warmup
      let warmupStart = ContinuousClock.now
      try await container.perform { (context: ModelContext) in
        let input = try await context.processor.prepare(
          input: UserInput(prompt: .messages([["role": "user", "content": "Hi"]])))
        _ = try MLXLMCommon.generate(
          input: input,
          parameters: GenerateParameters(maxTokens: 1, temperature: 0, prefillStepSize: 128),
          context: context, didGenerate: { (_: Int) in .more })
        Stream().synchronize()
      }
      Logger(subsystem: "dev.mox", category: "runtime").info(
        "model=\(model.id, privacy: .public) phase=warmup elapsed=\(String(describing: warmupStart.duration(to: .now)), privacy: .public)"
      )
      return MLXLoadedModel(container: container, contextSize: model.contextSize)
    } catch {
      Stream().synchronize()
      Memory.clearCache()
      throw BackendFailure(error, stage: stage)
    }
  }
}
private actor MLXLoadedModel: LoadedModel {
  private var container: ModelContainer?
  private let contextSize: Int
  init(container: ModelContainer, contextSize: Int) {
    self.container = container
    self.contextSize = contextSize
  }
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  {
    guard let container else { throw MoxError(.generationFailed, "Model has been unloaded.") }
    let messages: [[String: any Sendable]] = try request.messages.map {
      ["role": $0.role.rawValue, "content": try $0.text()]
    }
    let limit = contextSize
    return try await container.perform { (context: ModelContext) in
      defer {
        Stream().synchronize()
        Memory.clearCache()
      }
      var stage = BackendFailure.Stage.prepare
      do {
        try Task.checkCancellation()
        let input = try await context.processor.prepare(
          input: UserInput(prompt: .messages(messages)))
        let promptTokens = input.text.tokens.size
        guard promptTokens <= 8192, promptTokens + request.sampling.maxTokens <= limit else {
          throw MoxError(
            .contextLimit,
            "Tokenized input plus requested output exceeds model context or the M1 8192-token input budget; history was not truncated."
          )
        }
        try Task.checkCancellation()
        stage = .generate
        var decoder = ScalarStreamingDecoder(batchSize: 8) { context.tokenizer.decode(tokenIds: $0) }
        var decodingError: MoxError?
        var first = true
        // Intentionally use the official callback API: 3.31.4's AsyncStream path
        // allocates an unbounded intermediary. No custom sampler or token loop.
        let info: GenerateCompletionInfo = try MLXLMCommon.generate(
          input: input,
          parameters: GenerateParameters(
            maxTokens: request.sampling.maxTokens, temperature: request.sampling.temperature,
            topP: request.sampling.topP, prefillStepSize: 128),
          context: context,
          didGenerate: { (token: Int) in
            if output.isCancelled || Task.isCancelled { return .stop }
            if first {
              first = false
              if !output.emit(.phase("decode")) { return .stop }
            }
            do {
              let text = try decoder.append(token)
              if !text.isEmpty, !output.emit(.contentDelta(text)) { return .stop }
            } catch let error as MoxError {
              decodingError = error
              return .stop
            } catch {
              decodingError = MoxError(.generationFailed, "Incremental decoding failed.")
              return .stop
            }
            return .more
          })
        if let decodingError { throw decodingError }
        if !output.isCancelled, !Task.isCancelled {
          let tail = try decoder.finish()
          if !tail.isEmpty { output.emit(.contentDelta(tail)) }
        }
        let reason: FinishReason
        switch info.stopReason {
        case .stop: reason = .stop
        case .length: reason = .length
        case .cancelled: reason = .cancelled
        }
        Logger(subsystem: "dev.mox", category: "runtime").info(
          "request=\(request.id.uuidString, privacy: .public) peak_mlx_bytes=\(Memory.peakMemory)")
        return BackendResult(
          reason: reason,
          usage: Usage(
            promptTokens: info.promptTokenCount, outputTokens: info.generationTokenCount,
            prefillSeconds: info.promptTime, decodeSeconds: info.generateTime, peakMemoryBytes: Memory.peakMemory))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw BackendFailure(error, stage: stage)
      }
    }
  }
  func unload() async {
    container = nil
    Stream().synchronize()
    Memory.clearCache()
  }
}
