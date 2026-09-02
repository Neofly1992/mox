import Foundation
import MoxShared

/// v0.8.5+ — budget-aware LRU + pin registry for loaded models.
///
/// The actor owns *metadata only*: `id`, `weightsBytes`, `pinned`,
/// `lastTouched`. The actual `ModelContainer`s (or whatever the
/// caller wants to live alongside a registered model) stay outside
/// the registry, keyed by the same `id` in the caller's own
/// dictionary. Keeping the registry metadata-only is what lets the
/// algorithm stay testable: no `Any` boxing, no `Sendable` casts,
/// and the eviction policy reads as straight-line Swift.
//
//
/// **Status:** independent actor — `ModelRunner` does not yet route
/// through it. Phase 3b (next release) will wire `ModelRunner` to
/// register on `loadModel` and to release the `ModelContainer` when
/// the registry reports an eviction. Until then any caller can use
/// the registry on its own for budget-aware LRU semantics.
public actor ModelRegistry {

    /// A registered model slot. Pure data, no actor references.
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let weightsBytes: Int64
        public let pinned: Bool
        public var lastTouched: Date
        /// Monotonically-increasing tick assigned by the registry on
        /// every register/touch. Used as the LRU key because
        /// `Date()` resolution on macOS is coarser than the speed
        /// the actor sees between back-to-back register calls in
        /// tests — two registers inside the same millisecond would
        /// tie on `lastTouched`, and `min(by:)` would resolve the
        /// tie to whichever happens to land first in the dict
        /// (i.e. nondeterministically). The counter guarantees a
        /// total order without depending on the clock.
        public var tick: UInt64

        public init(id: String, weightsBytes: Int64, pinned: Bool, lastTouched: Date, tick: UInt64) {
            self.id = id
            self.weightsBytes = weightsBytes
            self.pinned = pinned
            self.lastTouched = lastTouched
            self.tick = tick
        }
    }
    /// so callers can send it across actor boundaries safely.
    public struct Snapshot: Sendable, Equatable {
        public let entries: [Entry]
        public let totalWeightsBytes: Int64
        public let cacheBudgetBytes: Int64
        public let cacheUsedBytes: Int64
    }

    private var entries: [String: Entry] = [:]
    private let cacheBudgetBytesStorage: Int64
    private var weightsTotalBytes: Int64 = 0
    /// Strictly-increasing sequence number. Every `register` and
    /// `touch` increments it; the value goes onto the new/updated
    /// `Entry.tick` so the LRU comparator has a total order.
    private var tickCounter: UInt64 = 0
    /// Build a registry with a precomputed cache budget. The
    /// constructor doesn't read `MemoryGuard`; the caller passes the
    /// numbers it wants. This keeps the actor pure for tests.
    public init(cacheBudgetBytes: Int64) {
        precondition(cacheBudgetBytes >= 0, "cacheBudgetBytes must be non-negative")
        self.cacheBudgetBytesStorage = cacheBudgetBytes
    }

    // MARK: - Mutations

    /// Register an id. If the id is already registered, the existing
    /// entry's bytes are replaced and `lastTouched` refreshed — the
    /// caller can fix up an entry's size without evicting it. The
    /// pin flag can only be *promoted* (false → true) by re-register;
    /// demotion needs an explicit `setPinned(id:false:)`.
    ///
    /// Returns the IDs that had to be evicted to make room, in
    /// eviction order. Empty when the new entry fits without
    /// pressure.
    @discardableResult
    public func register(
        id: String,
        weightsBytes: Int64,
        pinned: Bool = false
    ) async -> [String] {
        precondition(weightsBytes >= 0, "weightsBytes must be non-negative")
        // The new entry alone is bigger than the entire cache
        // budget. Eviction can't help — refuse. The caller is
        // expected to surface a clear error to the user; we don't
        // insert a half-loaded entry that future requests would
        // have to special-case.
        if weightsBytes > cacheBudgetBytesStorage, !entries.keys.contains(id) {
            return []
        }
        if var existing = entries[id] {
            weightsTotalBytes -= existing.weightsBytes
            tickCounter &+= 1
            existing.lastTouched = Date()
            let newPinned = existing.pinned || pinned
            entries[id] = Entry(
                id: existing.id,
                weightsBytes: weightsBytes,
                pinned: newPinned,
                lastTouched: existing.lastTouched,
                tick: tickCounter
            )
            weightsTotalBytes += weightsBytes
            return []
        }
        let eviction = await evictForSpace(neededBytes: weightsBytes, except: id)
        tickCounter &+= 1
        let entry = Entry(
            id: id,
            weightsBytes: weightsBytes,
            pinned: pinned,
            lastTouched: Date(),
            tick: tickCounter
        )
        entries[id] = entry
        weightsTotalBytes += weightsBytes
        return eviction
    }

    public func touch(id: String) async -> Bool {
        guard var entry = entries[id] else { return false }
        tickCounter &+= 1
        entry.lastTouched = Date()
        entry.tick = tickCounter
        entries[id] = entry
        return true
    }

    public func setPinned(id: String, pinned: Bool) async -> Bool? {
        guard let current = entries[id] else { return nil }
        let previous = current.pinned
        // setPinned doesn't refresh tick: a pin toggle is a config
        // change, not a "the model just served a request" event.
        // If callers want both, they can call touch() separately.
        entries[id] = Entry(
            id: current.id,
            weightsBytes: current.weightsBytes,
            pinned: pinned,
            lastTouched: current.lastTouched,
            tick: current.tick
        )
        return previous
    }

    /// release downstream resources). Unknown ids return nil.
    public func evict(id: String) async -> Entry? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        weightsTotalBytes -= entry.weightsBytes
        return entry
    }

    /// LRU-evict non-pinned entries until `neededBytes` fits in the
    /// cache budget, or until there's nothing left to evict.
    /// `except` is preserved: callers about to register an id don't
    /// want their own target evicted mid-call.
    @discardableResult
    func evictForSpace(neededBytes: Int64, except: String? = nil) async -> [String] {
        var evicted: [String] = []
        // If the new entry alone exceeds the whole budget, refuse:
        // eviction cannot help. The caller surfaces a clear error
        // to the user.
        if neededBytes > cacheBudgetBytesStorage {
            return evicted
        }
        while weightsTotalBytes + neededBytes > cacheBudgetBytesStorage {
            // Pick the oldest non-pinned entry not in `except`.
            // LRU key is the monotonic `tick`, not `lastTouched`:
            // the latter ties on sub-millisecond back-to-back
            // registers (Date() resolution on macOS) and `min(by:)`
            // then resolves to a nondeterministic dict order.
            let victim = entries.values
                .filter { !$0.pinned && $0.id != except }
                .min { $0.tick < $1.tick }
            guard let victim else { break }
            if await evict(id: victim.id) != nil {
                evicted.append(victim.id)
            } else {
                break
            }
        }
        return evicted
    }

    /// callers can send it across actor boundaries safely.
    public func snapshot() async -> Snapshot {
        Snapshot(
            entries: Array(entries.values),
            totalWeightsBytes: weightsTotalBytes,
            cacheBudgetBytes: cacheBudgetBytesStorage,
            cacheUsedBytes: max(cacheBudgetBytesStorage - weightsTotalBytes, 0)
        )
    }

    public func contains(id: String) async -> Bool {
        entries[id] != nil
    }

    public func isPinned(id: String) async -> Bool {
        entries[id]?.pinned ?? false
    }

    public func totalWeightsBytes() async -> Int64 {
        return weightsTotalBytes
    }

    public func cacheBudgetBytes() async -> Int64 {
        return cacheBudgetBytesStorage
    }
}