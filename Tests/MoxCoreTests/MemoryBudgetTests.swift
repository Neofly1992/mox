import Foundation
import Testing
@testable import MoxCore

/// `MemoryBudget` is a pure function — no actor, no I/O, no clock.
/// These tests pin every numeric boundary the registry depends on so
/// the constants in `MemoryBudget` can't silently drift.
@Suite("MemoryBudget")
struct MemoryBudgetTests {

    private static let GiB = Int64(1 << 30)

    @Test("32GB Mac: budget = 16 GB minus weights")
    func thirtyTwoGB() {
        let total = 32 * Self.GiB
        // Surplus = 16 GB. After 8 GB of resident weights, 8 GB cache.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: total, weightsPeakBytes: 8 * Self.GiB)
            == 8 * Self.GiB
        )
    }

    @Test("16GB Mac: surplus floor of 1 GB applies")
    func sixteenGB() {
        // 16 GB * 0.5 = 8 GB raw surplus. Not floored.
        // 4 GB weights → 4 GB cache.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: 16 * Self.GiB, weightsPeakBytes: 4 * Self.GiB)
            == 4 * Self.GiB
        )
    }

    @Test("1GB Mac: floor clamps the surplus to 1 GB")
    func oneGBFloor() {
        // 1 GB * 0.5 = 0.5 GB raw. Floor = 1 GB. Minus weights → 1 GB if no weights.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: 1 * Self.GiB, weightsPeakBytes: 0)
            == 1 * Self.GiB
        )
    }

    @Test("512MB Mac: floor still clamps to 1 GB")
    func halfGBFloor() {
        // 0.5 GB * 0.5 = 0.25 GB raw. Floor wins. Net = 1 GB - 0.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: 512 * 1024 * 1024, weightsPeakBytes: 0)
            == 1 * Self.GiB
        )
    }

    @Test("128GB Mac: cap clamps the surplus to 48 GB")
    func capAt48GB() {
        // 128 GB * 0.5 = 64 GB raw. Cap → 48 GB. Minus 32 GB weights → 16 GB.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: 128 * Self.GiB, weightsPeakBytes: 32 * Self.GiB)
            == 16 * Self.GiB
        )
    }

    @Test("Weights exceeding the clamped surplus collapse to zero")
    func overcommittedWeights() {
        // 32 GB total → 16 GB surplus. 20 GB weights → negative net → 0.
        #expect(
            MemoryBudget.cacheBudget(totalRAMBytes: 32 * Self.GiB, weightsPeakBytes: 20 * Self.GiB)
            == 0
        )
    }

    @Test("Surplus fraction override clamps differently")
    func customFraction() {
        // Same hardware, fraction = 0.25 instead of 0.5.
        // 32 GB * 0.25 = 8 GB. Floor not needed. Minus 4 GB weights → 4 GB.
        #expect(
            MemoryBudget.cacheBudget(
                totalRAMBytes: 32 * Self.GiB,
                weightsPeakBytes: 4 * Self.GiB,
                surplusFraction: 0.25
            )
            == 4 * Self.GiB
        )
    }
}