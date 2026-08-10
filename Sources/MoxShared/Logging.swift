import Foundation
import os

// MARK: - os.Logger instances (diagnostics only)
//
// Use these for everything that is *not* a user-facing CLI message:
//   - model load failures, network retries, socket closes, IPC spawn errors,
//     config write errors, file system failures, etc.
// All entries are visible in `Console.app` and `log show` (subsystem
// `com.mox` / `com.mox.server` / `com.mox.cli` / `com.mox.gui`).
// For a user-facing CLI message, print directly to stdout (or stderr for
// errors) — see "CLI user output" below.

public let moxLog       = Logger(subsystem: "com.mox",       category: "default")
public let moxServerLog = Logger(subsystem: "com.mox.server", category: "server")
public let moxCLILog    = Logger(subsystem: "com.mox.cli",    category: "cli")
public let moxGUILog    = Logger(subsystem: "com.mox.gui",    category: "gui")

// MARK: - CLI user output
//
// These are *not* logs. They are the contract between the CLI binary and
// the terminal: stdout for normal output, stderr for errors. Under launchd
// the launchd plist's `StandardOutPath` / `StandardErrorPath` redirect them
// to files (`mox debug logs` tails those), so we do not need to write
// the log file ourselves. There is deliberately no "log file sink" here:
// if you want to see the file, `mox debug logs` does it; if you want
// structured diagnostics, the `os.Logger` instances above are the
// single source of truth and `log show` is the only consumer.

/// Print a user-facing message to stdout. No log side-effect. `terminator`
/// defaults to "\n"; pass `""` to suppress (e.g. progress indicators).
public func moxPrint(_ message: String, terminator: String = "\n") {
    print(message, terminator: terminator)
}

/// Print a user-facing error to stderr. No log side-effect.
public func moxStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
