import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MoxShared
import MoxConvertCore
import Tokenizers

/// Drives an MLX LLM end-to-end: loads weights from a local model directory,
/// applies the processor + tokenizer, runs generation, and detokenizes the output.
public actor ModelRunner {
    public static let shared = ModelRunner()

    private var loadedModels: [String: Entry] = [:]
    private let memoryGuard = MemoryGuard.shared
    /// v0.8.6+ — budget-aware LRU + pin registry. Lazy: only
    /// materialised when the first model is loaded (cold start
    /// avoids the sysctl cost of probing total RAM up front).
    /// `nil` means "registry hasn't been built yet"; once any
    /// model is loaded the registry sticks around for the actor's
    /// lifetime.
    private var registry: ModelRegistry?
    /// Bytes-per-token approximation used by the registry when
    /// the caller doesn't supply a per-model weight size. Real
    /// weight bytes come from `ModelInfo.size` on `pullModel`; the
    /// fallback is conservative (over-counts) so a model never
    /// lands in the registry without enough budget reserved.
    private static let fallbackWeightsBytes: Int64 = 4 << 30 // 4 GiB

    public init() {}

    deinit {
        // Best-effort cleanup. ModelContainer has no explicit destructor;
        // clearing the map lets ARC reclaim the heavy model + cache.
        loadedModels.removeAll()
    }

    public func loadModel(id: String, config: AppConfig? = nil) async throws -> LoadedModel {
        if let entry = loadedModels[id] {
            // Re-registration refreshes `lastTouched` so the LRU
            // policy keeps this entry alive across pressure.
            await registry?.touch(id: id)
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

        // Tell the registry about this load BEFORE we touch the
        // container. If the entry is too big to ever fit, we
        // refuse before doing the expensive load. If it fits but
        // requires evicting siblings, the returned list tells us
        // which `ModelContainer`s to release on this actor.
        let registry = ensureRegistry()
        let weightsBytes = modelInfo.size > 0
            ? modelInfo.size
            : Self.fallbackWeightsBytes
        let pinned = config?.memory.pinnedModels.contains(id) ?? false
        let evictedIds = await registry.register(
            id: id,
            weightsBytes: weightsBytes,
            pinned: pinned
        )
        for evictedId in evictedIds {
            // LRU sweep kicked someone out. Release its container
            // on this actor (ModelContainer has no explicit close
            // but clearing the map lets ARC reclaim).
            loadedModels.removeValue(forKey: evictedId)
        }

        let container = try await loadModelContainer(from: modelPath, using: #huggingFaceTokenizerLoader())
        let manifest = (try? await ModelManager.shared.readManifest(at: modelPath))
        let persistedTier = manifest?.compatibility?.tier
        let persistedReason = manifest?.compatibility?.reason

        // v0.8 — fresh probe at load time. Refuse to bring the model
        // up if the on-disk config no longer matches the persisted
        // tier AND the fresh tier is `.incompatible`. Otherwise log
        // the verdict so the operator can see it via `/health`.
        let freshCompatibility = try? CompatibilityProbe.probe(at: modelPath)
        let freshTier = freshCompatibility?.tier
        let verdict: CompatibilityVerdict = Self.compatibilityVerdict(
            persisted: persistedTier,
            fresh: freshTier
        )
        if verdict == .incompatible {
            moxLog.error("model \(id, privacy: .public) load rejected: fresh probe incompatible")
            // Undo the registry registration since we're not
            // actually bringing the model up. Tolerant: the actor
            // is going down on the next line anyway.
            _ = await registry.evict(id: id)
            throw ModelError.unsupportedArchitecture(
                freshCompatibility?.reason ?? "compatibility probe rejected"
            )
        }
        if verdict == .mismatchDowngraded {
            moxLog.warning(
                "model \(id, privacy: .public) compatibility downgraded: persisted=\(persistedTier?.rawValue ?? "nil", privacy: .public) fresh=\(freshTier?.rawValue ?? "nil", privacy: .public)"
            )
        }

        let record = LoadedModel(
            id: id,
            modelPath: modelPath,
            loadedAt: Date(),
            compatibility: persistedTier,
            compatibilityReason: persistedReason,
            compatibilityFresh: freshTier,
            compatibilityVerdict: verdict
        )
        moxLog.info("model loaded: \(id, privacy: .public) path=\(modelPath.path, privacy: .public)")
        loadedModels[id] = Entry(container: container, record: record)
        return record
    }

    /// Materialise the registry lazily on the first model load.
    /// Reads total RAM once, computes the cache budget via
    /// `MemoryBudget.cacheBudget`, and parks it in `self.registry`.
    private func ensureRegistry() -> ModelRegistry {
        if let registry { return registry }
        let totalRAM = memoryGuard.getMemoryStatus().totalMemory
        // budget = clamp(totalRAM * 0.5, 1 GiB, 48 GiB) at zero
        // resident weights — we'll subtract as models load.
        let budget = MemoryBudget.cacheBudget(
            totalRAMBytes: Int64(totalRAM),
            weightsPeakBytes: 0
        )
        let new = ModelRegistry(cacheBudgetBytes: budget)
        self.registry = new
        return new
    }

    public func unloadModel(id: String) {
        loadedModels.removeValue(forKey: id)
        // Mirror the eviction on the registry so the cache budget
        // gets the bytes back. Tolerant: registry may not exist
        // if the runner was never asked to load anything.
        let registry = self.registry
        Task { await registry?.evict(id: id) }
    }


    public func unloadAll() {
        let ids = Array(loadedModels.keys)
        loadedModels.removeAll()
        let registry = self.registry
        Task {
            for id in ids { await registry?.evict(id: id) }
        }
    }

    public func isModelLoaded(id: String) -> Bool {
        loadedModels[id] != nil
    }

    public func listLoadedModels() -> [String] {
        Array(loadedModels.keys)
    }

    /// Forward to `ModelRegistry.snapshot()` for `/health` reporting.
    /// `nil` when the registry hasn't been built yet (no model has
    /// ever been loaded on this runner).
    public func registrySnapshot() async -> ModelRegistry.Snapshot? {
        guard let registry else { return nil }
        return await registry.snapshot()
    }

    /// Returns the model-family hint for a previously loaded model.
    /// Returns nil for models that aren't loaded yet (cold path).
    /// Callers should warm the model first via `loadModel` or
    /// `container(for:)` if they need the family hint.
    public func modelFamilyHint(for modelId: String) -> String? {
        loadedModels[modelId]?.record.modelFamily
    }

    /// Returns the full `LoadedModel` records currently in memory. Used by
    /// `/health` to surface capability fields without re-loading weights.
    public func snapshotLoaded() -> [LoadedModel] {
        loadedModels.values.map(\.record)
    }

    /// End-to-end smoke check after `loadModel`. Runs a tiny generation so
    /// the launchd-managed daemon refuses to come up on a broken install
    /// (corrupt weights, missing chat template, MLX kernel miss). Returns the
    /// generated text so callers can log it; throws on any failure.
    public func warmup(id: String, tokens: Int = 16) async throws -> String {
        let entries = [SendableChatEntry(role: "user", content: "hi")]
        let params = GenerateParameters(
            maxTokens: tokens,
            temperature: 0,
            topP: 1.0
        )
        do {
            return try await runGeneration(
                modelId: id, entries: entries, parameters: params
            )
        } catch {
            moxLog.error("warmup failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Single-token completion. Use for tool / agent flows; for chat prefer
    /// `chat` or `chatStream`.
    public func generate(
        modelId: String,
        prompt: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> String {
        let params = await Self.resolvedParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        let entries = [SendableChatEntry(role: "user", content: prompt)]
        return try await runGeneration(modelId: modelId, entries: entries, parameters: params)
    }

    /// Non-streaming chat completion; returns the assembled `ChatCompletionResponse`.
    public func chat(
        modelId: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) async throws -> ChatCompletionResponse {
        let params = await Self.resolvedParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        let entries = Self.toSendableEntries(messages)
        let assembled = try await runGeneration(
            modelId: modelId, entries: entries, parameters: params
        )

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

    /// Streaming chat completion. The `AsyncThrowingStream` propagates MLX
    /// generation errors to the caller so SSE / stdout consumers can surface
    /// a real `event: error` chunk instead of a silent close (see
    /// `MoxServer.handleAnthropicStream`).
    public func chatStream(
        modelId: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let entries = Self.toSendableEntries(messages)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let params = await Self.resolvedParameters(
                        maxTokens: maxTokens,
                        temperature: temperature,
                        topP: topP
                    )
                    let stream = try await self._generateStream(
                        modelId: modelId, entries: entries, parameters: params
                    )
                    for try await event in stream {
                        if case .chunk(let text) = event, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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

    /// Single non-streaming generation core, used by `generate` and `chat`.
    private func runGeneration(
        modelId: String,
        entries: [SendableChatEntry],
        parameters: GenerateParameters
    ) async throws -> String {
        let stream = try await _generateStream(
            modelId: modelId, entries: entries, parameters: parameters
        )
        var assembled = ""
        for try await event in stream {
            if case .chunk(let text) = event {
                assembled += text
            }
        }
        return assembled
    }

    /// Streaming core. Crosses the actor boundary into `container.perform { … }`
    /// to drive MLX generation, then returns an `AsyncStream<Generation>` that
    /// the caller drains. Errors are propagated to the caller's
    /// `AsyncThrowingStream` via the wrapping `chatStream`.
    private func _generateStream(
        modelId: String,
        entries: [SendableChatEntry],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        let container = try await container(for: modelId)
        return try await container.perform { context -> AsyncStream<Generation> in
            let chat = Self.sendableToChatMessages(entries)
            let lmInput = try await context.processor.prepare(input: UserInput(chat: chat))
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
        }
    }

    private func container(for modelId: String) async throws -> ModelContainer {
        if let entry = loadedModels[modelId] {
            // LRU refresh — a model that just served a request
            // should be the last to be evicted.
            await registry?.touch(id: modelId)
            return entry.container
        }
        // Cold path: load and pick up the entry that loadModel just
        // installed. `loadModel` registers on the registry, so the
        // second lookup is guaranteed to find it.
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

    /// Resolves the verdict from comparing persisted vs fresh tiers.
    /// Used by `loadModel` to decide whether to refuse the model.
    /// - `.match` if both are nil or both agree.
    /// - `.incompatible` if fresh is `.incompatible` OR the persisted
    ///   label says it's safe and the fresh probe says it's not.
    static func compatibilityVerdict(
        persisted: CompatibilityTier?,
        fresh: CompatibilityTier?
    ) -> CompatibilityVerdict {
        // Fresh `.incompatible` is the only verdict that triggers a
        // refusal — the persisted label is treated as advisory once
        // a fresh probe disagrees.
        if let fresh, fresh == .incompatible { return .incompatible }
        // Both nil = nothing to compare; treat as match so the cold
        // path doesn't false-positive.
        if persisted == nil && fresh == nil { return .match }
        // Any other mismatch (incl. persisted-only / fresh-only /
        // both-sides-agree-on-different-tier) is a downgrade — the
        // operator gets the verdict via `/health`.
        if persisted != fresh { return .mismatchDowngraded }
        return .match
    }

    private static func resolvedParameters(
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?
    ) async -> GenerateParameters {
        let defaults = (try? await ConfigManager.shared.load())?.defaults ?? AppConfig.ModelDefaults()
        return makeParameters(
            maxTokens: maxTokens ?? defaults.maxTokens,
            temperature: temperature ?? defaults.temperature,
            topP: topP ?? defaults.topP
        )
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

    /// Sendable mirror of `[Chat.Message]` for crossing `@Sendable` closures
    /// (e.g. `container.perform { ... }` callbacks). The closure reconstructs
    /// the full `UserInput` after the actor hop so the captured value is just
    /// plain strings — no `Chat.Message` ever escapes an actor boundary.
    private struct SendableChatEntry: Sendable {
        let role: String
        let content: String
    }

    private static func toSendableEntries(_ messages: [ChatMessage]) -> [SendableChatEntry] {
        messages.map { SendableChatEntry(role: $0.role.lowercased(), content: $0.content) }
    }

    private static func sendableToChatMessages(_ entries: [SendableChatEntry]) -> [Chat.Message] {
        entries.map { entry in
            switch entry.role {
            case "system": return .system(entry.content)
            case "assistant": return .assistant(entry.content)
            default: return .user(entry.content)
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
    /// Capability surface reported via `/health`. Populated by `loadModel`
    /// from the loaded tokenizer + chat template; absent on the cold path.
    public let modelFamily: String?
    public let supportsToolCalls: Bool
    public let contextWindow: Int?
    public let samplerDefaults: SamplerDefaults
    public let warmupTokens: Int?
    /// v0.8+ — compatibility tier from the manifest, surfaced via /health.
    public let compatibility: CompatibilityTier?
    public let compatibilityReason: String?
    /// v0.8+ — fresh probe at load time. If this disagrees with the
    /// persisted `compatibility` the loader logs a warning and rejects
    /// if the fresh probe is `.incompatible`.
    public let compatibilityFresh: CompatibilityTier?
    public let compatibilityVerdict: CompatibilityVerdict?
    public init(
        id: String,
        modelPath: URL,
        loadedAt: Date,
        modelFamily: String? = nil,
        supportsToolCalls: Bool = false,
        contextWindow: Int? = nil,
        samplerDefaults: SamplerDefaults = SamplerDefaults(),
        warmupTokens: Int? = nil,
        compatibility: CompatibilityTier? = nil,
        compatibilityReason: String? = nil,
        compatibilityFresh: CompatibilityTier? = nil,
        compatibilityVerdict: CompatibilityVerdict? = nil
    ) {
        self.id = id
        self.modelPath = modelPath
        self.loadedAt = loadedAt
        self.modelFamily = modelFamily
        self.supportsToolCalls = supportsToolCalls
        self.contextWindow = contextWindow
        self.samplerDefaults = samplerDefaults
        self.warmupTokens = warmupTokens
        self.compatibility = compatibility
        self.compatibilityReason = compatibilityReason
        self.compatibilityFresh = compatibilityFresh
        self.compatibilityVerdict = compatibilityVerdict
    }
}

/// Outcome of comparing persisted manifest tier against a fresh
/// `CompatibilityProbe`. Surfaced via `/health` so an operator can see
/// when a model on disk no longer matches its manifest label.
public enum CompatibilityVerdict: String, Codable, Sendable, Equatable {
    /// Fresh probe agrees with the persisted tier.
    case match
    /// Fresh probe disagrees but the new tier is still usable.
    case mismatchDowngraded
    /// Fresh probe disagrees and the new tier is `.incompatible`; the
    /// loader refused to bring the model up.
    case incompatible
}
