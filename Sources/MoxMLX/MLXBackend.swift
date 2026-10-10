import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Metal
import MoxCore
import MoxDomain
import OSLog

public struct MLXBackend: RuntimeBackend {
  private let configuredMemoryLimitBytes: Int
  public var memoryBudgetCeilingBytes: Int? {
    // Direct Core embedding cannot raise the native device/system safety ceiling.
    min(configuredMemoryLimitBytes, (try? Self.recommendedBudget()) ?? 0)
  }
  /// Composition creates one MLX backend per process. Limits are configured once,
  /// never changed by individual requests. Coordinator remains admission authority.
  public init(memoryLimit: Int) {
    configuredMemoryLimitBytes = max(0, memoryLimit)
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
  public func memorySnapshot() -> BackendMemorySnapshot? {
    let sample = Memory.snapshot()
    return .init(
      activeBytes: sample.activeMemory, cacheBytes: sample.cacheMemory,
      peakActiveBytes: sample.peakMemory)
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
        guard input.text.tokens.size <= GenerationLimits.maximumInputTokens,
          input.text.tokens.size + 1 <= model.contextSize else {
          throw MoxError(.contextLimit, "Warmup template exceeds model context or input token allowance.")
        }
        _ = try MLXLMCommon.generate(
          input: input,
          parameters: GenerateParameters(maxTokens: 1, temperature: 0, prefillStepSize: ModelResources.prefillStepTokens),
          context: context, didGenerate: { (_: Int) in .more })
        Stream().synchronize()
      }
      Logger(subsystem: "dev.mox", category: "runtime").info(
        "model=\(model.id, privacy: .public) phase=warmup elapsed=\(String(describing: warmupStart.duration(to: .now)), privacy: .public)"
      )
      return MLXLoadedModel(container: container, contextSize: model.contextSize,
        toolCapable: model.modelType == "qwen3")
    } catch {
      Stream().synchronize()
      Memory.clearCache()
      throw BackendFailure(error, stage: stage)
    }
  }
}
actor MLXLoadedModel: LoadedModel {
  private var container: ModelContainer?
  private let contextSize: Int
  private let toolCapable: Bool
  init(container: ModelContainer, contextSize: Int, toolCapable: Bool) {
    self.container = container
    self.contextSize = contextSize
    self.toolCapable = toolCapable
  }
  func generate(_ request: GenerationRequest, output: GenerationHandle) async throws
    -> BackendResult
  {
    guard let container else { throw MoxError(.generationFailed, "Model has been unloaded.") }
    guard request.toolChoice == .none || toolCapable else {
      throw MoxError(.unsupportedInput, "This model has no verified tool-call capability.")
    }
    let toolSpecs: [ToolSpec] = try request.tools.map { tool in
      let parameters = try JSONDecoder().decode(
        JSONValue.self, from: Data(tool.parametersJSON.utf8))
      return [
        "type": "function",
        "function": [
          "name": tool.name, "description": tool.description ?? "",
          "parameters": Self.nativeValue(parameters),
        ] as [String: any Sendable],
      ]
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
        let messages = try Self.chatMessages(request.messages)
        let input = try await context.processor.prepare(
          input: UserInput(chat: messages,
            tools: request.toolChoice == .auto ? toolSpecs : nil,
            additionalContext: toolCapable ? ["enable_thinking": false] : nil))
        let promptTokens = input.text.tokens.size
        guard promptTokens <= GenerationLimits.maximumInputTokens, promptTokens + request.sampling.maxTokens <= limit else {
          throw MoxError(
            .contextLimit,
            "Tokenized input plus requested output exceeds model context or the 8192-token input budget; history was not truncated."
          )
        }
        try Task.checkCancellation()
        output.emit(.promptTokens(promptTokens))
        stage = .generate
        var decoder = ScalarStreamingDecoder(batchSize: 8) { context.tokenizer.decode(tokenIds: $0) }
        var stopFilter = StopSequenceFilter(request.stopSequences)
        let processor = request.toolChoice == .auto
          ? ToolCallProcessor(format: context.configuration.toolCallFormat ?? .json,
              tools: toolSpecs) : nil
        var decodingError: MoxError?
        var first = true
        var emittedCalls = 0
        func emitCall(_ call: ToolCall) {
          guard request.tools.contains(where: { $0.name == call.function.name }),
            let arguments = try? String(
              data: JSONEncoder().encode(call.function.arguments), encoding: .utf8)
          else {
            decodingError = MoxError(.generationFailed, "Model produced an invalid tool call.")
            return
          }
          let id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
          if !output.emit(.toolCall(id: id, name: call.function.name, arguments: arguments)) {
            decodingError = MoxError(.slowConsumer, "Output consumer is too slow.")
          }
        }
        func emitVisible(_ visible: String) {
          if let processor {
            // 3.31.4's processor does not rescan a chunk after a different '<...>' tag.
            // Scalar-sized input lets it recognize a later <tool_call> without replacing
            // the upstream parser or changing the bounded callback transport.
            var ordinary = ""
            for scalar in visible.unicodeScalars {
              if let part = processor.processChunk(String(scalar)) { ordinary += part }
              while emittedCalls < processor.toolCalls.count {
                if !ordinary.isEmpty, !output.emit(.contentDelta(ordinary)) {
                  decodingError = MoxError(.slowConsumer, "Output consumer is too slow.")
                }
                ordinary = ""
                if decodingError != nil { return }
                emitCall(processor.toolCalls[emittedCalls])
                emittedCalls += 1
                if decodingError != nil { return }
              }
            }
            if ordinary.contains("<tool_call>") {
              decodingError = MoxError(.generationFailed, "Model produced an invalid tool call.")
              return
            }
            if !ordinary.isEmpty, !output.emit(.contentDelta(ordinary)) {
              decodingError = MoxError(.slowConsumer, "Output consumer is too slow.")
            }
          } else if !visible.isEmpty, !output.emit(.contentDelta(visible)) {
            decodingError = MoxError(.slowConsumer, "Output consumer is too slow.")
          }
        }
        func emitText(_ decoded: String) { emitVisible(stopFilter.accept(decoded)) }
        // Intentionally use the official callback API: 3.31.4's AsyncStream path
        // allocates an unbounded intermediary. No custom sampler or token loop.
        let info: GenerateCompletionInfo = try MLXLMCommon.generate(
          input: input,
          parameters: GenerateParameters(
            maxTokens: request.sampling.maxTokens, temperature: request.sampling.temperature,
            topP: request.sampling.topP, prefillStepSize: ModelResources.prefillStepTokens),
          context: context,
          didGenerate: { (token: Int) in
            if output.isCancelled || Task.isCancelled { return .stop }
            if first {
              first = false
              if !output.emit(.phase("decode")) { return .stop }
            }
            do {
              let text = try decoder.append(token)
              emitText(text)
              if decodingError != nil || stopFilter.matched != nil { return .stop }
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
          emitText(try decoder.finish())
          emitVisible(stopFilter.finish())
          if let decodingError { throw decodingError }
          if let residual = processor?.processEOS(returnBufferedText: true), !residual.isEmpty {
            guard !residual.contains("<tool_call>") else {
              throw MoxError(.generationFailed, "Model produced an incomplete tool call.")
            }
            if !output.emit(.contentDelta(residual)) {
              throw MoxError(.slowConsumer, "Output consumer is too slow.")
            }
          }
          if let processor {
            while emittedCalls < processor.toolCalls.count {
              emitCall(processor.toolCalls[emittedCalls])
              emittedCalls += 1
              if let decodingError { throw decodingError }
            }
          }
        }
        let reason: FinishReason
        if processor?.toolCalls.isEmpty == false { reason = .toolCalls }
        else if stopFilter.matched != nil { reason = .stopSequence }
        else { switch info.stopReason {
        case .stop: reason = .stop
        case .length: reason = .length
        case .cancelled: reason = .cancelled
        } }
        Logger(subsystem: "dev.mox", category: "runtime").info(
          "request=\(request.id.uuidString, privacy: .public) peak_mlx_bytes=\(Memory.peakMemory)")
        return BackendResult(
          reason: reason, usage: Usage(
            promptTokens: info.promptTokenCount, outputTokens: info.generationTokenCount,
            prefillSeconds: info.promptTime, decodeSeconds: info.generateTime, peakMemoryBytes: Memory.peakMemory),
          matchedStopSequence: stopFilter.matched)
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
  static func chatMessages(_ messages: [MoxDomain.Message]) throws -> [Chat.Message] {
    try messages.flatMap { message -> [Chat.Message] in
      var result: [Chat.Message] = []
      var text = ""
      var calls: [ToolCall] = []
      func flushText() {
        guard !text.isEmpty else { return }
        switch message.role {
        case .system: result.append(.system(text))
        case .user: result.append(.user(text))
        case .assistant: result.append(.assistant(text))
        case .tool: break
        }
        text = ""
      }
      func flushCalls() {
        guard !calls.isEmpty else { return }
        result.append(.assistant("", toolCalls: calls))
        calls = []
      }
      for block in message.content {
        switch block {
        case .text(let value):
          flushCalls()
          text += value
        case .toolCall(let id, let name, let arguments):
          guard message.role == .assistant else {
            throw MoxError(.unsupportedInput, "Tool calls require an assistant message.")
          }
          flushText()
          let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.utf8))
          calls.append(ToolCall(function: .init(name: name, arguments: object), id: id))
        case .toolResult(let id, let value, let isError):
          flushText()
          flushCalls()
          result.append(.tool(isError ? "Error: \(value)" : value, id: id))
        case .media:
          throw MoxError(.unsupportedInput, "Media input is not supported.")
        }
      }
      flushText()
      flushCalls()
      return result
    }
  }
  private static func nativeValue(_ value: JSONValue) -> any Sendable {
    switch value {
    case .null: return NSNull()
    case .bool(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .string(let value): return value
    case .array(let values): return values.map(nativeValue)
    case .object(let values): return values.mapValues(nativeValue)
    }
  }
}
