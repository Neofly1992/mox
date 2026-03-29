import Foundation
import MoxShared

public final class ModelRunner: @unchecked Sendable {
    public static let shared = ModelRunner()
    
    private var loadedModels: [String: LoadedModel] = [:]
    private let queue = DispatchQueue(label: "com.mox.modelrunner", attributes: .concurrent)
    private let memoryGuard = MemoryGuard.shared
    
    public init() {}
    
    public func loadModel(id: String, config: AppConfig? = nil) async throws -> LoadedModel {
        if let existing = queue.sync(execute: { loadedModels[id] }) {
            return existing
        }
        
        guard let modelInfo = try? ModelManager.shared.modelInfo(for: id) else {
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
        
        let loadedModel = LoadedModel(
            id: id,
            modelPath: modelPath,
            loadedAt: Date()
        )
        
        queue.async(flags: .barrier) {
            self.loadedModels[id] = loadedModel
        }
        
        return loadedModel
    }
    
    public func unloadModel(id: String) {
        queue.async(flags: .barrier) {
            self.loadedModels.removeValue(forKey: id)
        }
    }
    
    public func unloadAll() {
        queue.async(flags: .barrier) {
            self.loadedModels.removeAll()
        }
    }
    
    public func isModelLoaded(id: String) -> Bool {
        queue.sync {
            loadedModels[id] != nil
        }
    }
    
    public func generate(
        modelId: String,
        prompt: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> String {
        _ = try await loadModel(id: modelId)
        
        let config = try? ConfigManager().load()
        let tokens = maxTokens ?? config?.defaults.maxTokens ?? 2048
        let temp = temperature ?? config?.defaults.temperature ?? 0.7
        
        return "[MLX Generation Placeholder] Prompt: \(prompt.prefix(50))... (maxTokens: \(tokens), temp: \(temp))"
    }
    
    public func chat(
        modelId: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> ChatCompletionResponse {
        _ = try await loadModel(id: modelId)
        
        let config = try? ConfigManager().load()
        let prompt = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        
        let response = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int64(Date().timeIntervalSince1970),
            model: modelId,
            choices: [
                ChatCompletionResponse.Choice(
                    index: 0,
                    message: ChatCompletionResponse.AssistantMessage(content: "[MLX Chat Placeholder]"),
                    finishReason: "stop"
                )
            ],
            usage: ChatCompletionResponse.Usage(
                promptTokens: prompt.count / 4,
                completionTokens: 10,
                totalTokens: (prompt.count / 4) + 10
            )
        )
        
        return response
    }
    
    public func listLoadedModels() -> [String] {
        queue.sync {
            Array(loadedModels.keys)
        }
    }
}

public struct LoadedModel: Sendable {
    public let id: String
    public let modelPath: URL
    public let loadedAt: Date
}
