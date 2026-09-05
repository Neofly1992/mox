import Foundation
import Testing
@testable import MoxCLI
@testable import MoxShared

/// Tests for `mox doctor` (v0.11 P1.1).
///
/// The check functions run unconditionally on every invocation —
/// no model needs to be loaded, no daemon needs to be running.
/// We assert on the *shape* of the report (5 checks, well-known
/// names, status enums round-trip through JSON) rather than the
/// host-specific outcome of any individual check.
@Suite("`mox doctor`")
struct DoctorTests {

    @Test("DoctorCheck round-trips through JSON")
    func checkEncodes() throws {
        let original = DoctorCheck(
            name: "Test",
            status: .ok,
            message: "all good",
            fix: nil
        )
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"name\":\"Test\""))
        #expect(json.contains("\"status\":\"OK\""))
        // `fix: nil` is encoded by omitting the key under default
        // JSONEncoder settings — we just verify the key isn't
        // present for an absent fix.
        #expect(!json.contains("\"fix\":"))
    }

    @Test("All five expected check names are present")
    func allCheckNamesPresent() async {
        let checks = await Doctor.runAllChecks()
        let names = Set(checks.map(\.name))
        // The doctor pipeline runs 5 fixed checks. New checks
        // should be added deliberately — a regression here means
        // someone silently removed one.
        #expect(names == ["System", "MLX", "Model dir", "Daemon", "Network"])
    }

    @Test("Every check has a non-empty message")
    func everyCheckHasMessage() async {
        let checks = await Doctor.runAllChecks()
        for check in checks {
            #expect(!check.message.isEmpty, "check \(check.name) has empty message")
        }
    }

    @Test("Status is one of OK / WARN / FAIL")
    func statusInKnownSet() async {
        let checks = await Doctor.runAllChecks()
        for check in checks {
            let raw = check.status.rawValue
            #expect(["OK", "WARN", "FAIL"].contains(raw))
        }
    }

    @Test("Only FAIL status carries a fix hint (by convention)")
    func fixOnlyOnFailure() async {
        // We don't *require* this (WARN rows often have a fix too,
        // e.g. "run `mox pull`"), but FAIL should never appear
        // without one.
        let checks = await Doctor.runAllChecks()
        for check in checks where check.status == .fail {
            #expect(check.fix != nil, "FAIL row '\(check.name)' missing fix")
        }
    }

    @Test("DoctorReport JSON shape is { checks: [...] }")
    func reportShape() async throws {
        let checks = await Doctor.runAllChecks()
        let report = DoctorReport(checks: checks)
        let data = try JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"checks\""))
        // 5 entries inline.
        #expect(json.contains("\"System\""))
        #expect(json.contains("\"Network\""))
    }
}