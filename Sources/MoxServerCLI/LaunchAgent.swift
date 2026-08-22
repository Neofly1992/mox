import Foundation
import MoxCore
import MoxShared

// MARK: - LaunchAgentError

enum LaunchAgentError: Error, CustomStringConvertible {
    case runningAsRoot
    case binaryNotFound(String)
    case launchctlFailed(command: String, terminationStatus: Int32, stderr: String)
    case configWriteFailed(String)
    case plistWriteFailed(String)

    var description: String {
        switch self {
        case .runningAsRoot:
            return "refusing to install as root (uid 0) — LaunchAgents must be owned by the user"
        case .binaryNotFound(let name):
            return "\(name) not found in \(BinaryLocator.defaultCandidates.joined(separator: ", ")) or $PATH"
        case .launchctlFailed(let command, let status, let stderr):
            return "launchctl \(command) exited \(status): \(stderr)"
        case .configWriteFailed(let message):
            return "could not update ~/.mox/config.json: \(message)"
        case .plistWriteFailed(let message):
            return "could not write plist: \(message)"
        }
    }
}

// MARK: - Shell helper
//
// Wraps `Process` so callers can see the exit code and stderr, not just the
// stdout the previous implementation surfaced. Without the exit code the
// caller cannot tell "launchctl refused" from "label absent".

struct ShellResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

func runShell(_ executable: String, _ arguments: String...) throws -> ShellResult {
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return ShellResult(
        stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        terminationStatus: process.terminationStatus
    )
}

/// Runs `launchctl` and converts a non-zero exit (other than the "already
/// bootstrapped" idiom) into a thrown `LaunchAgentError`. Use this for any
/// launchctl call we care about the result of; use `runShell` directly for
/// informational calls like `launchctl print`.
func launchctl(_ arguments: String...) throws -> ShellResult {
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let result = ShellResult(
        stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        terminationStatus: process.terminationStatus
    )
    if result.terminationStatus != 0
        && !result.stderr.contains("Already bootstrapped") {
        throw LaunchAgentError.launchctlFailed(
            command: "launchctl " + arguments.joined(separator: " "),
            terminationStatus: result.terminationStatus,
            stderr: result.stderr
        )
    }
    return result
}


// MARK: - LaunchAgent

enum LaunchAgent {
    static let label = "com.mox.server"

    /// The launchd user domain specifier for the current user. `gui/<uid>`
    /// is required because user LaunchAgents live in the user GUI domain,
    /// not the bootstrap domain that bare `launchctl <verb> <label>` resolves
    /// against. The previous implementation omitted this and produced
    /// "Could not find service" errors on every start/stop.
    static var domainSpecifier: String {
        "gui/\(getuid())"
    }

    /// Fully-qualified launchd reference for this agent, suitable for
    /// `launchctl kickstart -k <ref>` and `launchctl kill SIGTERM <ref>`.
    static var launchdReference: String {
        "\(domainSpecifier)/\(label)"
    }

    static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mox/config.json")
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mox")
    }

    static var stdoutLog: URL { logDirectory.appendingPathComponent("daemon.log") }
    static var stderrLog: URL { logDirectory.appendingPathComponent("daemon.err") }

    /// Loads the user's AppConfig, falling back to defaults if the file is
    /// missing or unreadable. Daemon host/port come from this so the GUI's
    /// Settings tab and the CLI agree on the same address.
    static func loadAppConfig() -> AppConfig {
        do {
            return try ConfigManager.shared.loadSync()
        } catch {
            return AppConfig()
        }
    }

    /// Builds the launchd plist XML using the user's configured host/port and
    /// the resolved binary path. `ThrottleInterval` bounds the KeepAlive
    /// respawn rate to 30s so a crash loop does not flood `daemon.log`.
    static func plistData(binary: String, config: AppConfig) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                binary,
                "daemon",
                "--host", config.server.host,
                "--port", String(config.server.port),
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "StandardOutPath": stdoutLog.path,
            "StandardErrorPath": stderrLog.path,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
    }

    /// Writes ~/.mox/config.json with the `daemon.enabled` flag, preserving
    /// every other key the user already had (mirrors, memory, defaultSource,
    /// server, defaults). The order matters: we write the config first so the
    /// daemon-enabled state on disk always matches the plist presence — if
    /// `launchctl bootstrap` then fails, the caller can roll back the config
    /// by re-running `uninstall`.
    static func writeConfig(enabled: Bool) throws {
        let fm = FileManager.default
        let parent = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        } else {
            // Seed with AppConfig defaults so a fresh install isn't an empty
            // JSON object — MoxGUI's MoxGUIConfig also assumes the typed
            // keys are present.
            if let data = try? JSONEncoder().encode(AppConfig()),
               let base = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj = base
            }
        }
        obj["daemon"] = ["enabled": enabled]

        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configURL, options: [.atomic])
    }

    /// Atomically writes the plist to disk. `.atomic` writes to a sibling
    /// temp file first, then renames over the destination — a SIGKILL or
    /// disk-full mid-write can no longer leave launchd with a half-formed
    /// plist it refuses to load.
    static func writePlist(_ data: Data) throws {
        let fm = FileManager.default
        let parent = plistPath.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: logDirectory.path) {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: plistPath, options: [.atomic])
        } catch {
            throw LaunchAgentError.plistWriteFailed("\(error)")
        }
    }

    /// Reads the existing plist, if any, into a comparable dictionary. Used
    /// to decide whether `install` is a no-op (idempotent) or a destructive
    /// overwrite of a user-edited plist.
    static func readExistingPlist() -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistPath) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func dictionariesEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        // PropertyListSerialization's output types are NSNumber/NSString, so
        // do a normalised NSDictionary comparison rather than rely on Equatable.
        let na = NSDictionary(dictionary: a)
        let nb = NSDictionary(dictionary: b)
        return na.isEqual(to: nb as! [AnyHashable: Any])
    }

    /// Installs and bootstraps the launchd agent. Idempotent: if the plist on
    /// disk already matches what we would generate and `daemon.enabled` is
    /// already `true`, no work is done. If anything fails after the plist is
    /// written, we attempt a best-effort rollback so we never leave the
    /// system in a half-installed state.
    static func install() throws {
        if getuid() == 0 {
            throw LaunchAgentError.runningAsRoot
        }

        let config = loadAppConfig()
        guard let binary = BinaryLocator.locate(named: "mox-server") else {
            throw LaunchAgentError.binaryNotFound("mox-server")
        }
        let desiredPlist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                binary,
                "daemon",
                "--host", config.server.host,
                "--port", String(config.server.port),
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "StandardOutPath": stdoutLog.path,
            "StandardErrorPath": stderrLog.path,
        ]

        // Idempotency check: if the existing plist is byte-identical to what
        // we would write, just confirm the agent is bootstrapped.
        if let existing = readExistingPlist(),
           dictionariesEqual(existing, desiredPlist) {
            do {
                _ = try launchctl("bootstrap", domainSpecifier, plistPath.path)
            } catch LaunchAgentError.launchctlFailed(_, _, let stderr)
                where stderr.contains("Already bootstrapped") {
                // Idempotent re-run on an already-bootstrapped agent.
            } catch {
                throw error
            }
            try? writeConfig(enabled: true)
            moxPrint("Installed (already up to date): \(plistPath.path)")
            moxServerLog.info("launchd plist install no-op (idempotent) at \(plistPath.path, privacy: .public)")
            return
        }

        // Plist changed (or absent): write it, then bootstrap. We commit the
        // config update first so the daemon-enabled flag on disk matches the
        // plist presence; if bootstrap fails we still surface the error and
        // let `uninstall` clean up.
        let plistXML = try PropertyListSerialization.data(
            fromPropertyList: desiredPlist,
            format: .xml,
            options: 0
        )
        try writePlist(plistXML)
        try writeConfig(enabled: true)

        do {
            _ = try launchctl("bootstrap", domainSpecifier, plistPath.path)
        } catch LaunchAgentError.launchctlFailed(_, let status, let stderr) {
            moxServerLog.error("launchctl bootstrap failed (status \(status)): \(stderr, privacy: .public)")
            // Best-effort rollback so we don't leave a bootstrapped-but-
            // invalid state behind. Errors here are swallowed because the
            // primary failure is the bootstrap result above.
            _ = try? launchctl("bootout", launchdReference)
            try? FileManager.default.removeItem(at: plistPath)
            throw LaunchAgentError.launchctlFailed(
                command: "bootstrap",
                terminationStatus: status,
                stderr: stderr
            )
        }

        moxPrint("Installed and bootstrapped: \(plistPath.path)")
        moxServerLog.info("launchd plist installed and bootstrapped at \(plistPath.path, privacy: .public)")
    }

    /// Boots the agent out of launchd before deleting the plist. The previous
    /// implementation deleted the plist first, which left launchd holding an
    /// orphan reference and refused to re-register the agent on next install.
    static func uninstall() throws {
        if getuid() == 0 {
            throw LaunchAgentError.runningAsRoot
        }
        // Exit 0 = booted out, or "could not find service" (rc 3 with a
        // specific stderr). Anything else is a hard error.
        let okStatuses: Set<Int32> = [0, 3]
        let bootResult = try runShell(
            "/bin/launchctl", "bootout", launchdReference
        )
        // Exit 0 = booted out, or "could not find service" (rc 3 with a
        // specific stderr). Anything else is a hard error.
        if !okStatuses.contains(bootResult.terminationStatus) {
            throw LaunchAgentError.launchctlFailed(
                command: "bootout",
                terminationStatus: bootResult.terminationStatus,
                stderr: bootResult.stderr
            )
        }

        if FileManager.default.fileExists(atPath: plistPath.path) {
            try FileManager.default.removeItem(at: plistPath)
        }
        try writeConfig(enabled: false)

        moxPrint("Uninstalled \(label)")
        moxServerLog.info("launchd agent \(label, privacy: .public) uninstalled")
    }
}