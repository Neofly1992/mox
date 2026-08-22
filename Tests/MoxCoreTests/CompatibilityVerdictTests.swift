import Foundation
import Testing
@testable import MoxCore
@testable import MoxConvertCore
@testable import MoxShared

/// v0.8 — loadModel must compare the persisted manifest tier against a
/// fresh probe and surface the verdict via `/health`. The verdict
/// classifier is pure; tests pin the matrix.
@Suite("CompatibilityVerdict")
struct CompatibilityVerdictTests {

    @Test("Both nil -> match")
    func bothNil() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: nil, fresh: nil) == .match
        )
    }

    @Test("Both equal -> match")
    func bothEqual() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: .mlxBuiltin, fresh: .mlxBuiltin) == .match
        )
    }

    @Test("Fresh incompatible overrides persisted label -> incompatible")
    func freshIncompatibleWins() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: .mlxBuiltin, fresh: .incompatible) == .incompatible
        )
        #expect(
            ModelRunner.compatibilityVerdict(persisted: nil, fresh: .incompatible) == .incompatible
        )
    }

    @Test("Persisted != fresh but both usable -> mismatchDowngraded")
    func mismatchUsable() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: .mlxBuiltin, fresh: .arOnly) == .mismatchDowngraded
        )
        #expect(
            ModelRunner.compatibilityVerdict(persisted: .mlxBuiltin, fresh: .communityUnverified) == .mismatchDowngraded
        )
    }

    @Test("Persisted has tier, fresh is nil -> mismatchDowngraded")
    func persistedOnly() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: .mlxBuiltin, fresh: nil) == .mismatchDowngraded
        )
    }

    @Test("Persisted nil, fresh has tier -> mismatchDowngraded")
    func freshOnly() {
        #expect(
            ModelRunner.compatibilityVerdict(persisted: nil, fresh: .mlxBuiltin) == .mismatchDowngraded
        )
    }
}