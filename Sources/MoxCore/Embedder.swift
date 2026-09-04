import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers


/// v0.11 P0.2 — hardware-aware embedding model loader + inference path.
///
/// `MoxEmbedder` is an actor that:
/// 1. Loads embedder models from `~/.mox/models/<id>` (set up via
///    `mox pull <id>`; the embedder does **not** download — that's a
///    `mox pull` responsibility).
/// 2. Caches loaded containers in-memory, keyed by model id, LRU-evicted
///    when the count exceeds `maxCachedModels` (default 2).
/// 3. Provides an async `embed(inputs:model:)` API that returns
///    `[[Float]]` per OpenAI's `/v1/embeddings` wire shape.
///
/// Lifecycle:
/// - Process-wide singleton (`MoxEmbedder.shared`); the server hands
///   it requests directly. Per-model load is ~hundreds of MB on first
///   call; subsequent calls are hot.
/// - LRU evicts the least-recently-used embedder on each new load
///   once the cache is full. Caller can force eviction via
///   `unloadAll()` (used by `mox-server stop`).
///
/// Failure modes (typed errors, mapped to HTTP status by the server):
/// - `MoxEmbedderError.modelNotFound(id)` — local `~/.mox/models/<id>`
///   doesn't exist. Server returns 404 + "run `mox pull <id>`" hint.
/// - `MoxEmbedderError.loadFailed(modelId, underlying)` — first-load
///   tokenizer / model decode failure. Server returns 502.
/// - `MoxEmbedderError.inferenceFailed(modelId, underlying)` — model
///   loaded but inference (encode + forward + pool) failed. Server
///   returns 500.
public actor MoxEmbedder {

    /// Singleton — the embedder is process-wide state. LRU cache and
    /// configuration live here so the server can stay stateless.
    public static let shared = MoxEmbedder()

    /// Resolved embedder model id (e.g. `BAAI/bge-small-en-v1.5`).
    public typealias ModelID = String

    /// Cap on simultaneously cached embedder containers. 2 covers the
    /// common case (e.g. bge-small + a multilingual fallback) without
    /// pressing 32 GB+ hosts. Power users can call `unloadAll()` to
    /// force a swap.
    private let maxCachedModels: Int

    /// LRU order; first = least-recently-used. Maintained on every
    /// `embed()` call. We move the touched id to the back, so the
    /// front of the list is the eviction candidate.
    private var lruOrder: [ModelID] = []
    /// id → loaded container. Container is an actor on the mlx side
    /// (its `perform` API is `Sendable`-friendly via the
    /// `EmbedderModelContext` indirection).
    private var containers: [ModelID: EmbedderModelContainer] = [:]

    /// Cached `ModelConfiguration` per id — saves a registry lookup
    /// per embed call. Populated lazily on first load.
    private var configurations: [ModelID: ModelConfiguration] = [:]

    public init(maxCachedModels: Int = 2) {
        precondition(maxCachedModels >= 1, "maxCachedModels must be >= 1")
        self.maxCachedModels = maxCachedModels
    }

    /// Embed a batch of texts. `modelId` is any HF id previously
    /// pulled into `~/.mox/models/<id>`. Empty input returns `[]`
    /// without touching the model (parity with OpenAI).
    public func embed(inputs: [String], modelId: ModelID) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let container = try await ensureLoaded(modelId: modelId)
        return await container.perform { (model, tokenizer, pooling) -> [[Float]] in
            // Encode each input separately (encoder has per-call
            // state). Pad to the longest in this batch.
            let tokenIdBatches = inputs.map { text in
                tokenizer.encode(text: text, addSpecialTokens: true)
            }
            let maxLength = tokenIdBatches.reduce(0) { max($0, $1.count) }
            // Pad with eosTokenId (matches upstream README's
            // embedding example). Fallback to 0 if no eos known.
            let padId = tokenizer.eosTokenId ?? 0
            let padded = stacked(tokenIdBatches.map { ids in
                MLXArray(ids + Array(repeating: padId, count: maxLength - ids.count))
            })
            let mask = (padded .!= padId)
            let tokenTypes = MLXArray.zeros(like: padded)
            let forward = model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            // Normalize + apply layer norm when the model declares
            // a pooling strategy; otherwise fall back to plain
            // pooling. The upstream README's example passes
            // `normalize: true, applyLayerNorm: true` for nomic
            // — the model's preferred defaults propagate via
            // `poolingStrategy`.
            let pooled = pooling(forward, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    /// Force-evict all cached embedders. Idempotent. Use for memory
    /// pressure recovery or test isolation.
    public func unloadAll() {
        containers.removeAll()
        configurations.removeAll()
        lruOrder.removeAll()
    }

    /// Number of currently cached embedders. Exposed for tests and
    /// the `/health` runtime field (parallel to `loadedModelCount`).
    public func cachedCount() -> Int {
        containers.count
    }

    // MARK: - LRU bookkeeping

    private func ensureLoaded(modelId: ModelID) async throws -> EmbedderModelContainer {
        if let existing = containers[modelId] {
            touch(modelId)
            return existing
        }
        // v0.11 P0.2 — local-directory only. mox's `mox pull` already
        // downloads the model to `~/.mox/models/<id>`; the embedder
        // reuses that path. If the dir doesn't exist, surface
        // `modelNotFound` so the server can return 404 + a hint.
        let localDir: URL
        do {
            localDir = try await ModelManager.shared.modelPath(for: modelId)
        } catch {
            throw MoxEmbedderError.modelNotFound(modelId: modelId)
        }
        configurations[modelId] = ModelConfiguration(id: modelId)
        let container: EmbedderModelContainer
        do {
            container = try await EmbedderModelFactory.shared.loadContainer(
                from: localDir,
                using: #huggingFaceTokenizerLoader()
            )
        } catch {
            throw MoxEmbedderError.loadFailed(modelId: modelId, underlying: error)
        }
        containers[modelId] = container
        lruOrder.append(modelId)
        evictIfNeeded()
        return container
    }

    private func touch(_ id: ModelID) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func evictIfNeeded() {
        while containers.count > maxCachedModels, let victim = lruOrder.first {
            lruOrder.removeFirst()
            containers.removeValue(forKey: victim)
            configurations.removeValue(forKey: victim)
        }
    }
}

/// Errors surfaced by `MoxEmbedder`. Mapped to HTTP status by the
/// `MoxServer` handler.
public enum MoxEmbedderError: Error, LocalizedError, Sendable {
    case modelNotFound(modelId: String)
    case loadFailed(modelId: String, underlying: Error)
    case inferenceFailed(modelId: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "Embedder model '\(id)' not found on disk. Run `mox pull <id>` first; the embedder loads from ~/.mox/models/<id>."
        case .loadFailed(let id, let underlying):
            return "Failed to load embedder '\(id)': \(underlying.localizedDescription)"
        case .inferenceFailed(let id, let underlying):
            return "Embedder '\(id)' inference failed: \(underlying.localizedDescription)"
        }
    }
}
