import Foundation
import Testing
@testable import MoxGUIClient
import MoxShared

/// `HardwareSuggestion.current()` runs the live `HardwareClassifier`
/// probe — it doesn't take any actor, model, or filesystem. The tests
/// here only assert the *shape* of the returned value (non-empty ids,
/// total RAM sane, tier/notes populated). They don't pin a specific
/// model id or RAM tier because the host running the test is unknown.
@Suite("HardwareSuggestion")
struct HardwareSuggestionTests {

    @Test("current() returns non-empty recommended IDs on a real Mac")
    func returnsRecommendations() {
        let s = HardwareSuggestion.current()
        // On any Mac the suggester emits at least one id (Intel path
        // still emits the toy-tier fallback).
        #expect(!s.recommendedIDs.isEmpty)
        // `totalRAMGB` is a `Int`, but the constructor coerces
        // 0-byte memsize reads to 0. We only assert it's >= 0.
        #expect(s.totalRAMGB >= 0)
        // `tier` is always one of the four cases; check the raw
        // string is non-empty.
        #expect(!s.tier.rawValue.isEmpty)
    }

    @Test("current() returns non-empty notes (user-facing string)")
    func returnsNotes() {
        let s = HardwareSuggestion.current()
        #expect(!s.notes.isEmpty)
    }

    @Test("current() with empty installed list never claims an installed match")
    func noInstalledMatchByDefault() {
        let s = HardwareSuggestion.current(installedModelIDs: [])
        #expect(s.alreadyInstalled == nil)
    }

    @Test("current() with an installed id that matches recommendation surface it")
    func installedMatchSurfaces() {
        let s = HardwareSuggestion.current()
        // Pick the first recommendation as the "installed" one.
        guard let first = s.recommendedIDs.first else {
            // No recommendations → nothing to test (Intel toy fallback
            // still emits ids, so this is a hard failure).
            Issue.record("expected at least one recommendation")
            return
        }
        let withInstalled = HardwareSuggestion.current(installedModelIDs: [first])
        #expect(withInstalled.alreadyInstalled == first)
    }

    @Test("current() with a non-matching installed id leaves alreadyInstalled nil")
    func noInstalledMatchForUnknownId() {
        let s = HardwareSuggestion.current(installedModelIDs: ["some/random/id/that/is/not/recommended"])
        #expect(s.alreadyInstalled == nil)
    }

    @Test("Equatable: same args produce equal suggestions")
    func equatableRoundTrip() {
        // Two calls on the same host produce equal suggestions
        // (HardwareClassifier has no I/O, no clock; reproducible).
        let a = HardwareSuggestion.current()
        let b = HardwareSuggestion.current()
        #expect(a == b)
    }
}