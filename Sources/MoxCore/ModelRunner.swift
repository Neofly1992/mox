import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MoxShared
import Tokenizers

/// Drives an MLX LLM end-to-end: loads weights from a local model directory,
/// applies the processor + tokenizer, runs generation, and detokenizes the output.
public actor ModelRunner {
    public static let shared = ModelRunner()

    private var loadedModels: [String: Entry] = [:]
    private let memoryGuard = MemoryGuard.shared

    public init() {}

    // MARK: - Public API

    public func loadModel(id: String, config: AppConfig? = nil) async throws -> LoadedModel {
        if let entry = loadedModels[id] {
            return entry.record
        }

        guard let modelInfo = try? await ModelManager.shared.modelInfo(for: id) else {
            throw ModelError.notFound(id)
        }

        let memoryStatus = memoryGuard.getMemoryStatus()
        if !memoryStatus.canAllocate {
            throw MemoryError.insufficientMemory(
                required: Double(modelInfo.size) / (1024 * 1024 * 1024),
                available: memoryStatus.availableGB
            )
        }

        let modelPath = URL(fileURLWithPath: modelInfo.path)
        try Self.requireModelDirectory(at: modelPath)

        let container = try await loadModelContainer(directory: modelPath)
        let record = LoadedModel(id: id, modelPath: modelPath, loadedAt: Date())
        loadedModels[id] = Entry(container: container, record: record)
        return record
    }

    public func unloadModel(id: String) {
        loadedModels.removeValue(forKey: id)
    }

    public func unloadAll() {
        loadedModels.removeAll()
    }

    public func isModelLoaded(id: String) -> Bool {
        loadedModels[id] != nil
    }

    public func listLoadedModels() -> [String] {
        Array(loadedModels.keys)
    }

    public func generate(
        modelId: String,
        prompt: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> String {
        let defaults = await Self.resolvedDefaults()
        let params = Self.makeParameters(
            maxTokens: maxTokens ?? defaults.maxTokens,
            temperature: temperature ?? defaults.temperature,
            topP: topP ?? defaults.topP
        )
        let input = UserInput(prompt: prompt)
        return try await runGeneration(modelId: modelId, input: input, parameters: params)
    }

    public func chat(
        modelId: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> ChatCompletionResponse {
        let defaults = await Self.resolvedDefaults()
        let tokens = maxTokens ?? defaults.maxTokens
        let temp = temperature ?? defaults.temperature
        let p = topP ?? defaults.topP
        let params = Self.makeParameters(maxTokens: tokens, temperature: temp, topP: p)

        let chat = Self.toChatMessages(messages)
        let input = UserInput(chat: chat)

        let container = try await container(for: modelId)
        let stream = try await container.perform { context -> AsyncStream<Generation> in
            let lmInput = try await context.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: lmInput, parameters: params, context: context)
        }
        var assembled = ""
        for await event in stream {
            if case .chunk(let text) = event {
                assembled += text
            }
        }

        let promptTokens = Self.estimatePromptTokens(messages)
        let completionTokens = max(1, assembled.count / 4)
        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int64(Date().timeIntervalSince1970),
            model: modelId,
            choices: [
                ChatCompletionResponse.Choice(
                    index: 0,
                    message: ChatCompletionResponse.AssistantMessage(content: assembled),
                    finishReason: "stop"
                )
            ],
            usage: ChatCompletionResponse.Usage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
        )
    }

    /// Streams the assistant response chunk-by-chunk as it is generated.
    /// - Returns: an `AsyncStream` of decoded text chunks.
    public func chatStream(
        modelId: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) -> AsyncStream<String> {
        let chat = Self.toChatMessages(messages)
        let input = UserInput(chat: chat)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    // Config + parameter resolution happens inside the Task so
                    // the public method can keep its synchronous signature
                    // even though `resolvedDefaults()` is now async (it
                    // touches the actor-isolated `ConfigManager`).
                    let defaults = await Self.resolvedDefaults()
                    let tokens = maxTokens ?? defaults.maxTokens
                    let temp = temperature ?? defaults.temperature
                    let p = topP ?? defaults.topP
                    let params = Self.makeParameters(maxTokens: tokens, temperature: temp, topP: p)

                    let container = try await self.container(for: modelId)
                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        let lmInput = try await context.processor.prepare(input: input)
                        return try MLXLMCommon.generate(
                            input: lmInput, parameters: params, context: context)
                    }
                    for await event in stream {
                        switch event {
                        case .chunk(let text):
                            if !text.isEmpty {
                                continuation.yield(text)
                            }
                        case .info:
                            break
                        case .toolCall:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private struct Entry {
        let container: ModelContainer
        let record: LoadedModel
    }

    private func runGeneration(
        modelId: String,
        input: UserInput,
        parameters: GenerateParameters
    ) async throws -> String {
        let container = try await container(for: modelId)
        let stream = try await container.perform { context -> AsyncStream<Generation> in
            let lmInput = try await context.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
        }
        var assembled = ""
        for await event in stream {
            if case .chunk(let text) = event {
                assembled += text
            }
        }
        return assembled
    }

    private func container(for modelId: String) async throws -> ModelContainer {
        if let entry = loadedModels[modelId] {
            return entry.container
        }
        _ = try await loadModel(id: modelId)
        guard let entry = loadedModels[modelId] else {
            throw ModelError.notFound(modelId)
        }
        return entry.container
    }

    // MARK: - Static helpers

    private static func makeParameters(
        maxTokens: Int,
        temperature: Double,
        topP: Double
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature),
            topP: Float(topP)
        )
    }

    private static func resolvedDefaults() async -> AppConfig.ModelDefaults {
        (try? await ConfigManager.shared.load())?.defaults ?? AppConfig.ModelDefaults()
    }

    private static func toChatMessages(_ messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { msg in
            switch msg.role.lowercased() {
            case "system":
                return .system(msg.content)
            case "assistant":
                return .assistant(msg.content)
            default:
                return .user(msg.content)
            }
        }
    }

    private static func estimatePromptTokens(_ messages: [ChatMessage]) -> Int {
        let total = messages.reduce(0) { $0 + $1.content.count }
        return max(1, total / 4)
    }

    private static func requireModelDirectory(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ModelError.invalidPath(url.path)
        }
        let configFile = url.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configFile.path) else {
            throw ModelError.invalidPath("Missing config.json in \(url.path)")
        }
    }
}

public struct LoadedModel: Sendable {
    public let id: String
    public let modelPath: URL
    public let loadedAt: Date
}
