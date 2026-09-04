import Foundation
import Testing
@testable import MoxCore

/// `DefaultModelSuggester.suggest` is a pure function over `HardwareClassifier`.
/// We exercise every tier boundary from §9.4 + the Intel-fallback + the
/// zero-memory probe-failed branch.
@Suite("DefaultModelSuggester")
struct DefaultModelSuggesterTests {

    private static let GiB = UInt64(1 << 30)

    /// Build a stub classifier so tests don't have to touch the live
    /// `sysctl` / `uname` probes.
    private func stub(
        ramGB: Int,
        appleSilicon: Bool = true,
        brand: String = "Apple M4"
    ) -> HardwareClassifier {
        HardwareClassifier(
            isAppleSilicon: appleSilicon,
            totalMemoryBytes: UInt64(ramGB) * Self.GiB,
            brandString: brand,
            chipGeneration: .m4
        )
    }

    @Test("toy tier: < 16 GB → sub-2B models")
    func toyTier() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 8))
        #expect(s.tier == .toy)
        #expect(s.totalRAMGB == 8)
        // The smallest ids must appear before bigger ones — caller walks
        // in order, so this ordering is load-bearing.
        #expect(s.recommendedIDs.first == "Qwen/Qwen2.5-0.5B-Instruct")
        #expect(s.recommendedIDs.contains(where: { $0.contains("0.5B") || $0.contains("1.1B") || $0.contains("1.5B") }))
    }

    @Test("small tier: 16-32 GB → 7-9B 4-bit")
    func smallTier() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 16))
        #expect(s.tier == .small)
        #expect(s.totalRAMGB == 16)
        #expect(s.recommendedIDs.first == "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(s.recommendedIDs.contains(where: { $0.contains("7B") || $0.contains("8B") }))
    }

    @Test("medium tier: 32-64 GB → 14-27B 4-bit")
    func mediumTier() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 48))
        #expect(s.tier == .medium)
        #expect(s.totalRAMGB == 48)
        #expect(s.recommendedIDs.contains(where: { $0.contains("14B") || $0.contains("32B") }))
    }

    @Test("large tier: 64+ GB → 27B+/70B+ 4-bit")
    func largeTier() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 96))
        #expect(s.tier == .large)
        #expect(s.totalRAMGB == 96)
        #expect(s.recommendedIDs.contains(where: { $0.contains("32B") || $0.contains("70B") || $0.contains("72B") }))
    }

    @Test("Tier boundary at 16 GB: exactly 16 → small")
    func smallTierBoundary16() {
        // `<` vs `<=` boundary check — 16 GB lands in small, not toy.
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 16))
        #expect(s.tier == .small)
    }

    @Test("Tier boundary at 32 GB: exactly 32 → medium")
    func mediumTierBoundary32() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 32))
        #expect(s.tier == .medium)
    }

    @Test("Tier boundary at 64 GB: exactly 64 → large")
    func largeTierBoundary64() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 64))
        #expect(s.tier == .large)
    }

    @Test("Intel Mac: short-circuits to toy + Rosetta note, no MLX recommendation")
    func intelFallback() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 32, appleSilicon: false, brand: "Intel(R) Core(TM) i7"))
        #expect(s.tier == .toy)
        #expect(s.notes.contains("Intel"))
        // Still emits *something* — caller decides whether to bail.
        #expect(!s.recommendedIDs.isEmpty)
    }

    @Test("Zero-byte memory (probe failed): falls into toy tier, not medium")
    func zeroMemoryFallback() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 0))
        // 0 GB < 16 → toy, not the 32-GB default ROADMAP §9.4 hinted at.
        #expect(s.tier == .toy)
        #expect(s.totalRAMGB == 0)
    }

    @Test("Every tier carries a non-empty notes string (shown to user)")
    func everyTierHasNotes() {
        for ram in [8, 16, 48, 96] {
            let s = DefaultModelSuggester().suggest(for: stub(ramGB: ram))
            #expect(!s.notes.isEmpty, "tier=\(s.tier) must not be silent")
        }
    }

    @Test("Recommended IDs are unique within a suggestion (no duplicate heads)")
    func idsUnique() {
        let s = DefaultModelSuggester().suggest(for: stub(ramGB: 16))
        #expect(Set(s.recommendedIDs).count == s.recommendedIDs.count)
    }
}