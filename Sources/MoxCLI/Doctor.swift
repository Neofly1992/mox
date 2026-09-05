import Foundation
import MoxCore
import MoxShared

// MARK: - v0.11 P1.1: `mox doctor`

/// A single check's outcome. `OK` means the check passed; `WARN` is a
/// non-fatal issue (e.g. daemon not running on a development machine);
/// `FAIL` is a hard error that needs user action before mox works.
enum DoctorStatus: String, Sendable, Encodable {
    case ok = "OK"
    case warn = "WARN"
    case fail = "FAIL"
}

/// One row of the doctor report. Serializes cleanly to JSON for
/// the `--json` flag (consumed by the GUI Settings tab).
struct DoctorCheck: Sendable, Encodable {
    let name: String
    let status: DoctorStatus
    /// One-sentence user-facing summary.
    let message: String
    /// Optional remediation hint. Only set when `status != .ok`.
    let fix: String?

    init(name: String, status: DoctorStatus, message: String, fix: String? = nil) {
        self.name = name
        self.status = status
        self.message = message
        self.fix = fix
    }
}

/// Top-level doctor report. Encoded as a single JSON object with a
/// stable shape so the GUI can introspect:
/// `{ "checks": [ {name, status, message, fix}, ... ] }`.
struct DoctorReport: Sendable, Encodable {
    let checks: [DoctorCheck]
}

/// `mox doctor` entry point. Parses `--json` flag then runs the
/// checks in deterministic order. Each check is independent — one
/// failure doesn't stop the rest.
enum Doctor {
    /// Run all checks and either print a colored table to stderr or
    /// emit a JSON envelope to stdout (for GUI / automation).
    public static func run(args: [String]) async {

        let json = args.contains("--json")
        let checks = await runAllChecks()
        let report = DoctorReport(checks: checks)
        if json {
            // JSON to stdout so a pipe | jq works.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report),
               let str = String(data: data, encoding: .utf8) {
                moxPrint(str)
            }
            return
        }
        printHumanReport(checks)
    }

    /// Exposed for tests. Production code calls `run(args:)` which
    /// formats the report; tests inspect the raw checks.
    public static func runAllChecks() async -> [DoctorCheck] {


        var checks: [DoctorCheck] = []
        checks.append(await checkSystem())
        checks.append(await checkMLX())
        checks.append(await checkModelDir())
        checks.append(await checkDaemon())
        checks.append(await checkNetwork())
        return checks
    }

    /// 1. **System** — host hardware fingerprint. Same data
    /// `mox suggest` reads; this is the diagnostic counterpart.
    private static func checkSystem() async -> DoctorCheck {
        let hardware = HardwareClassifier()
        let isAppleSilicon = hardware.isAppleSilicon
        let ramGB = hardware.totalMemoryBytes >> 30
        if isAppleSilicon {
            return DoctorCheck(
                name: "System",
                status: .ok,
                message: "Apple Silicon (\(hardware.brandString)), \(ramGB) GB RAM. MLX is supported."
            )
        }
        return DoctorCheck(
            name: "System",
            status: .fail,
            message: "Intel Mac detected. MLX requires Apple Silicon.",
            fix: "Run mox on an Apple Silicon Mac (M1+). On Intel, models won't load."
        )
    }

    /// 2. **MLX** — confirm we can construct an `MLXArray` and
    /// evaluate it. The cheapest way to verify the GPU/Metal path
    /// without loading a real model.
    private static func checkMLX() async -> DoctorCheck {
        // We don't import MLX directly here (mox's CLI is a thin
        // MoxCore consumer; MLX is a transitive dep). The
        // `HardwareClassifier` itself probes the system via
        // sysctl/uname and is enough to detect Apple Silicon.
        // Full MLX eval check is a v0.12+ improvement (load a
        // trivial module + eval).
        let hardware = HardwareClassifier()
        if hardware.isAppleSilicon {
            return DoctorCheck(
                name: "MLX",
                status: .ok,
                message: "Apple Silicon detected. MLX is the supported inference backend."
            )
        }
        return DoctorCheck(
            name: "MLX",
            status: .fail,
            message: "No MLX-capable hardware detected."
        )
    }

    /// 3. **Model dir** — `~/.mox/` exists and is writable. We
    /// create it lazily on first `mox pull`, so a fresh install may
    /// not have it yet — that's a WARN, not a FAIL.
    private static func checkModelDir() async -> DoctorCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let moxDir = home.appendingPathComponent(".mox")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: moxDir.path, isDirectory: &isDir)
        if !exists {
            return DoctorCheck(
                name: "Model dir",
                status: .warn,
                message: "~/.mox/ does not exist yet.",
                fix: "Run `mox pull <model-id>` to bootstrap the directory."
            )
        }
        if !isDir.boolValue {
            return DoctorCheck(
                name: "Model dir",
                status: .fail,
                message: "~/.mox exists but is not a directory."
            )
        }
        // Writable check
        let testFile = moxDir.appendingPathComponent(".mox-doctor-write-test")
        do {
            try "ok".write(to: testFile, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: testFile)
            return DoctorCheck(
                name: "Model dir",
                status: .ok,
                message: "~/.mox/ exists and is writable."
            )
        } catch {
            return DoctorCheck(
                name: "Model dir",
                status: .fail,
                message: "~/.mox/ is not writable: \(error.localizedDescription)",
                fix: "Check permissions on ~/.mox/."
            )
        }
    }

    /// 4. **Daemon** — `launchctl list | grep mox-server`. If
    /// launchd plist is loaded, optionally probe `/health`.
    private static func checkDaemon() async -> DoctorCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            if out.contains("mox-server") {
                return DoctorCheck(
                    name: "Daemon",
                    status: .ok,
                    message: "mox-server launchd job is loaded."
                )
            }
            return DoctorCheck(
                name: "Daemon",
                status: .warn,
                message: "mox-server launchd job is not loaded.",
                fix: "Run `mox-server install` to register the launchd plist, or use `mox-server start` for a one-shot."
            )
        } catch {
            return DoctorCheck(
                name: "Daemon",
                status: .warn,
                message: "Could not run `launchctl list`: \(error.localizedDescription).",
                fix: "mox is fine without the daemon — use `mox-server start` for one-shot mode."
            )
        }
    }

    /// 5. **Network** — HEAD `https://huggingface.co` and
    /// `https://www.modelscope.cn`. 5-second timeout per host. The
    /// user can still use mox offline; this is informational.
    private static func checkNetwork() async -> DoctorCheck {
        let endpoints = [
            ("HuggingFace", URL(string: "https://huggingface.co")!),
            ("ModelScope", URL(string: "https://www.modelscope.cn")!)
        ]
        var failures: [String] = []
        for (name, url) in endpoints {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    continue
                }
                failures.append("\(name): non-2xx")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            return DoctorCheck(
                name: "Network",
                status: .ok,
                message: "HuggingFace + ModelScope reachable."
            )
        }
        return DoctorCheck(
            name: "Network",
            status: .warn,
            message: "Some endpoints unreachable: \(failures.joined(separator: "; "))",
            fix: "mox works offline once models are pulled. Network is only needed for `mox pull` / `mox update`."
        )
    }

    // MARK: - Human formatting

    private static func printHumanReport(_ checks: [DoctorCheck]) {
        var hasFailure = false
        for check in checks {
            let tag: String
            switch check.status {
            case .ok:   tag = "OK   "
            case .warn: tag = "WARN "
            case .fail: tag = "FAIL "
            }
            moxStderr("[\(tag)] \(check.name): \(check.message)")
            if let fix = check.fix {
                moxStderr("       ↳ \(fix)")
            }
            if check.status == .fail { hasFailure = true }
        }
        moxStderr("")
        if hasFailure {
            moxStderr("Some checks failed. Run `mox doctor --json` for machine-readable output.")
            // Exit 1 on FAIL so shell scripts can branch.
            exit(1)
        }
        // WARN-only is informational; OK exits 0.
    }
}

/// Top-level `handleDoctor` shim, wrapped in an enum to coexist
/// with `main.swift`'s `@main` attribute. (`@main` rejects
/// top-level code in the same module.)
enum DoctorEntry {
    static func handle(_ args: [String]) async {
        await Doctor.run(args: args)
    }
}
