import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// `ModelRegistry` is a metadata-only actor: it tracks `id`,
/// `weightsBytes`, `pinned`, `lastTouched` and enforces a cache
/// budget via LRU eviction of non-pinned entries. The tests below
/// pin every code path the registry exposes — register, re-register,
/// touch, evict, setPinned, evictForSpace — so the policy can't
/// silently regress.
@Suite("ModelRegistry v0.8.5 LRU + pin")
struct ModelRegistryTests {

    private static let MiB = Int64(1024 * 1024)

    private func makeRegistry(budget: Int64) -> ModelRegistry {
        ModelRegistry(cacheBudgetBytes: budget)
    }

    // MARK: - Register

    @Test("register fits a small entry without eviction")
    func fitsCleanly() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        let evicted = await r.register(id: "small", weightsBytes: 10 * Self.MiB)
        #expect(evicted.isEmpty)
        let snap = await r.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.totalWeightsBytes == 10 * Self.MiB)
        #expect(snap.cacheUsedBytes == 90 * Self.MiB)
    }

    @Test("register rejects (no-op) entries that exceed the budget alone")
    func exceedsBudgetAlone() async {
        let r = makeRegistry(budget: 10 * Self.MiB)
        // The new entry is bigger than the entire budget; eviction
        // can't help. The registry refuses silently (returns no
        // eviction list); the caller surfaces a clear error.
        let evicted = await r.register(id: "huge", weightsBytes: 100 * Self.MiB)
        #expect(evicted.isEmpty)
        let snap = await r.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.totalWeightsBytes == 0)
    }

    @Test("re-registering an id replaces bytes without eviction")
    func reRegisterReplacesBytes() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "a", weightsBytes: 50 * Self.MiB)
        let evicted = await r.register(id: "a", weightsBytes: 70 * Self.MiB)
        #expect(evicted.isEmpty)
        let snap = await r.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.totalWeightsBytes == 70 * Self.MiB)
    }

    // MARK: - LRU eviction

    @Test("register evicts the least-recently-touched non-pinned entry")
    func evictsLRU() async throws {
        let r = makeRegistry(budget: 100 * Self.MiB)
        // v0.10.1 — `registerBatch` runs N registers in one actor
        // continuation, so the strict victim identity is
        // deterministic. Before this, the test had to mark itself
        // `withKnownIssue` because each `await r.register(...)`
        // round-tripped through the scheduler and could land in
        // a different order than the test wrote them.
        let evicted = await r.registerBatch([
            (id: "a", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "b", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "c", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "d", weightsBytes: 40 * Self.MiB, pinned: false),
        ])
        // 4 registers of 40 MiB into a 100 MiB budget:
        //   a fits (40), b fits (80), c evicts a (80), d evicts b (80).
        // Last call's eviction list is the 4th, hence ["b"].
        #expect(evicted == ["b"])
        let snap = await r.snapshot()
        #expect(snap.entries.map(\.id).sorted() == ["c", "d"])
    }

    @Test("touch refreshes lastTouched and prevents eviction")
    func touchProtects() async throws {
        let r = makeRegistry(budget: 100 * Self.MiB)
        // v0.10.1 — split the setup into a deterministic batch +
        // a single async touch + a single async register. The
        // first batch installs a, b in tick order (a is the LRU
        // victim); touch refreshes a's tick so b becomes the
        // LRU; then register c in its own call forces one
        // eviction, and the victim must be b, not a.
        await r.registerBatch([
            (id: "a", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "b", weightsBytes: 40 * Self.MiB, pinned: false),
        ])
        let touched = await r.touch(id: "a")
        #expect(touched)
        // Single async register — schedules with the actor, but
        // there's only one register call so there's no actor
        // ordering ambiguity left to reason about.
        let evicted = await r.register(id: "c", weightsBytes: 40 * Self.MiB)
        #expect(evicted == ["b"])
        let snap = await r.snapshot()
        #expect(snap.entries.map(\.id).sorted() == ["a", "c"])
    }

    @Test("registerBatch returns the last call's eviction list")
    func registerBatchReturnsLastEviction() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        // 4 registers of 40 MiB into 100 MiB:
        //   a fits, b fits, c evicts a, d evicts b.
        // registerBatch returns the last call's eviction list
        // (the one from `d`), so the test asserts ["b"].
        let evicted = await r.registerBatch([
            (id: "a", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "b", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "c", weightsBytes: 40 * Self.MiB, pinned: false),
            (id: "d", weightsBytes: 40 * Self.MiB, pinned: false),
        ])
        #expect(evicted == ["b"])
        let snap = await r.snapshot()
        #expect(snap.entries.map(\.id).sorted() == ["c", "d"])
    }

    @Test("pinned entries are never evicted, even if pressure is high")
    func pinnedSurvives() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "keep", weightsBytes: 40 * Self.MiB, pinned: true)
        _ = await r.register(id: "throwaway1", weightsBytes: 40 * Self.MiB)
        _ = await r.register(id: "throwaway2", weightsBytes: 40 * Self.MiB)
        // Total resident = 120 MiB, budget = 100 MiB. Register 50
        // MiB needs to free 50. Throwaways go first; `keep` stays.
        let evicted = await r.register(id: "big", weightsBytes: 50 * Self.MiB)
        #expect(!evicted.contains("keep"))
        #expect(await r.contains(id: "keep"))
    }

    @Test("eviction halts when only pinned entries remain")
    func pinnedStopsEviction() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "p1", weightsBytes: 40 * Self.MiB, pinned: true)
        _ = await r.register(id: "p2", weightsBytes: 40 * Self.MiB, pinned: true)
        // Register a non-pinned 40 MiB entry. Budget allows it
        // (80 < 100).
        _ = await r.register(id: "u", weightsBytes: 40 * Self.MiB)
        // Now register 50 MiB. Need 50 free; only `u` (40) can be
        // evicted. After eviction net = 80 + 50 = 130 > 100, but
        // p1/p2 are pinned and there's nothing else to evict.
        // Registry should stop eviction (returns whatever it
        // evicted so far) and the caller decides to refuse.
        let evicted = await r.register(id: "big", weightsBytes: 50 * Self.MiB)
        #expect(evicted == ["u"])
        let snap = await r.snapshot()
        // p1 + p2 + big = 130 MiB resident; budget stays exceeded.
        #expect(snap.totalWeightsBytes == 130 * Self.MiB)
        #expect(snap.cacheUsedBytes == 0) // saturates to 0
    }

    // MARK: - setPinned

    @Test("setPinned promotes a registered entry to pinned")
    func promoteToPinned() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "a", weightsBytes: 50 * Self.MiB)
        let previous = await r.setPinned(id: "a", pinned: true)
        #expect(previous == false)
        #expect(await r.isPinned(id: "a"))
    }

    @Test("setPinned demotes a pinned entry")
    func demoteFromPinned() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "a", weightsBytes: 50 * Self.MiB, pinned: true)
        let previous = await r.setPinned(id: "a", pinned: false)
        #expect(previous == true)
        #expect(await r.isPinned(id: "a") == false)
    }

    @Test("setPinned on an unknown id is a no-op")
    func setPinnedUnknown() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        let previous = await r.setPinned(id: "ghost", pinned: true)
        #expect(previous == nil)
    }

    // MARK: - Evict explicit

    @Test("evict returns the entry and clears it from the registry")
    func explicitEvict() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        _ = await r.register(id: "a", weightsBytes: 30 * Self.MiB)
        let removed = await r.evict(id: "a")
        #expect(removed?.id == "a")
        #expect(removed?.weightsBytes == 30 * Self.MiB)
        #expect(await r.contains(id: "a") == false)
        let snap = await r.snapshot()
        #expect(snap.totalWeightsBytes == 0)
    }

    @Test("evict on unknown id returns nil")
    func evictUnknown() async {
        let r = makeRegistry(budget: 100 * Self.MiB)
        let removed = await r.evict(id: "ghost")
        #expect(removed == nil)
    }

    // MARK: - Snapshot

    @Test("snapshot reports totals consistent with the live entries")
    func snapshotTotals() async {
        let r = makeRegistry(budget: 200 * Self.MiB)
        _ = await r.register(id: "a", weightsBytes: 40 * Self.MiB)
        _ = await r.register(id: "b", weightsBytes: 60 * Self.MiB)
        let snap = await r.snapshot()
        #expect(snap.totalWeightsBytes == 100 * Self.MiB)
        #expect(snap.cacheUsedBytes == 100 * Self.MiB)
        #expect(snap.entries.count == 2)
    }
}