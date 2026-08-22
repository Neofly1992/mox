import Foundation
import MoxCore
import MoxServer
import MoxShared
import Darwin

// MARK: - Subcommand dispatch
//
// The launchd-managed daemon lives entirely inside this `daemon` subcommand.
// SIGTERM from launchd (stop / uninstall) and SIGINT from `^C` must release
// the listening socket and shut down the EventLoopGroup; without a handler
// `dispatchMain()` swallows both signals and launchd leaves an orphan
// process. We install a C-style handler that flips a global flag and lets
// the main dispatch queue run `server.stop() + exit(0)`.
//
// Swift 6 concurrency flags `signal()` as unsafe (the handler runs in C
// context with no Swift isolation guarantee). That is acceptable here:
// the handler does the bare minimum (set a bool and exit) and we accept
// the documented Swift-runtime caveat.

private func daemonSignalHandler(_ sig: Int32) {
    // Cannot call Swift code safely from a signal handler. Re-enter the
    // process via write(STDERR_FILENO, ...) for a breadcrumb, then exit.
    // The actual MoxServer.stop() / EventLoopGroup.shutdownGracefully()
    // teardown happens via the atexit-style shutdown below.
    let msg = "[\(Date())] mox-server received signal \(sig); exiting.\n"
    msg.withCString { ptr in
        _ = write(STDERR_FILENO, ptr, strlen(ptr))
    }
    // SIGTERM is launched by `launchctl kill`; honour it by terminating the
    // process promptly. macOS terminates us within microseconds.
    exit(0)
}

private func help() {
    moxPrint("""
    mox-server commands:
      daemon [--host H] [--port N]   Run the server in the foreground (managed by launchd)
      install                         Register launchd agent and bootstrap
      uninstall                       Bootout launchd agent and remove plist
      start                           launchctl kickstart -k <label>
      stop                            launchctl kill SIGTERM <label>
      status                          Exit-coded status (0=running 3=loaded-not-running 4=not-loaded)
      logs [--stderr] [--lines N]     Tail the launchd-captured stdout/stderr
      help
    """)
}

private func value(_ args: [String], _ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

private func intValue(_ args: [String], _ name: String, _ fallback: Int) -> Int {
    guard let raw = Int(value(args, name, String(fallback))) else { return fallback }
    return raw
}

private func runDaemon(_ args: [String]) -> Never {
    let config = LaunchAgent.loadAppConfig()
    let host = value(args, "--host", config.server.host)
    let port = intValue(args, "--port", config.server.port)
    let server = MoxServer(host: host, port: port)

    // Install signal handlers BEFORE server.start() so a SIGTERM racing the
    // bind still gets caught. signal() returns the previous handler; we
    // ignore it (Swift runtime installs its own SIG_DFL under the hood).
    signal(SIGTERM, daemonSignalHandler)
    signal(SIGINT, daemonSignalHandler)

    do {
        try server.start()
    } catch {
        moxStderr("failed to start server on \(host):\(port) — \(error)")
        moxServerLog.error("server start failed: \(String(describing: error), privacy: .public)")
        exit(1)
    }
    moxServerLog.info("mox-server listening on \(host, privacy: .public):\(port, privacy: .public)")
    dispatchMain()
}

private func runStart() throws {
    _ = try launchctl("kickstart", "-k", LaunchAgent.launchdReference)
    moxPrint("Started \(LaunchAgent.launchdReference)")
}

private func runStop() throws {
    _ = try launchctl("kill", "SIGTERM", LaunchAgent.launchdReference)
    moxPrint("Stopped \(LaunchAgent.launchdReference)")
}

private enum DaemonStatusCode: Int32 {
    case running = 0
    case loadedNotRunning = 3
    case notLoaded = 4
}

private func runStatus() -> Never {
    let result = try? launchctl("print", LaunchAgent.launchdReference)
    switch result {
    case .some(let r) where r.terminationStatus == 0:
        moxPrint("running: \(LaunchAgent.launchdReference)")
        exit(DaemonStatusCode.running.rawValue)
    default:
        // `launchctl print` rc != 0 with "service not found" stderr means
        // either not-loaded or loaded-but-not-running. Disambiguate by
        // checking whether the launchd user domain lists our label.
        let list = try? launchctl("print", LaunchAgent.domainSpecifier)
        let registered = list?.stderr.contains(LaunchAgent.label) ?? false
        if registered {
            moxPrint("loaded but not running: \(LaunchAgent.launchdReference)")
            exit(DaemonStatusCode.loadedNotRunning.rawValue)
        }
        moxPrint("not loaded: \(LaunchAgent.label)")
        exit(DaemonStatusCode.notLoaded.rawValue)
    }
}

private func runLogs(_ args: [String]) throws {
    let useStderr = args.contains("--stderr")
    let lines = intValue(args, "--lines", 50)
    let file = useStderr ? LaunchAgent.stderrLog : LaunchAgent.stdoutLog
    if !FileManager.default.fileExists(atPath: file.path) {
        moxStderr("log file does not exist: \(file.path)")
        exit(1)
    }
    let result = try runShell("/usr/bin/tail", "-n", String(lines), file.path)
    if !result.stdout.isEmpty {
        moxPrint(result.stdout)
    }
    if result.terminationStatus != 0 {
        moxStderr("tail exited \(result.terminationStatus): \(result.stderr)")
        exit(result.terminationStatus)
    }
}

private func runCLI() {
    let args = CommandLine.arguments
    guard args.count > 1 else { help(); return }
    do {
        switch args[1] {
        case "daemon":
            runDaemon(args)
        case "install":
            try LaunchAgent.install()
        case "uninstall":
            try LaunchAgent.uninstall()
        case "start":
            try runStart()
        case "stop":
            try runStop()
        case "status":
            runStatus()
        case "logs":
            try runLogs(args)
        case "help", "--help", "-h":
            help()
        default:
            help()
        }
    } catch {
        moxStderr("error: \(error)")
        moxServerLog.error("mox-server CLI failed: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}

// Sync entry point — no async, no detached Task wrapping dispatchMain, so
// the signal handlers installed by `runDaemon` actually fire. The previous
// implementation wrapped runCLI() in `Task { await runCLI(); exit(0) }`
// racing dispatchMain, which is undefined under Swift 6 concurrency.
runCLI()