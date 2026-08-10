import Foundation
import MoxCore
import MoxServer
import MoxShared
func help() {
    moxPrint("mox-server commands: daemon install uninstall start stop status logs")
}

func value(_ args: [String], _ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

func runCLI() async {
    let args = CommandLine.arguments
    guard args.count > 1 else { help(); return }
    do {
        switch args[1] {
        case "daemon":
            let host = value(args, "--host", "127.0.0.1")
            let port = Int(value(args, "--port", "11555")) ?? 11555
            let server = MoxServer(host: host, port: port)
            try server.start()
            // Diagnostic only — stdout capture is for the launchd log file.
            moxServerLog.info("mox-server listening on \(host):\(port) (subsystem com.mox.server)")
            dispatchMain()

        case "install":
            try LaunchAgent.install()

        case "uninstall":
            try LaunchAgent.uninstall()

        case "start":
            moxPrint(runShell("/bin/launchctl", "start", LaunchAgent.label))

        case "stop":
            moxPrint(runShell("/bin/launchctl", "stop", LaunchAgent.label))

        case "status":
            let out = runShell("/bin/launchctl", "list")
            moxPrint(out.contains(LaunchAgent.label) ? out : "not loaded")

        case "logs":
            // User-facing tail of the launchd-captured stdout. This is the
            // contract for `mox debug logs`; do not add an os.Logger entry
            // here — the underlying server's `moxServerLog` is the
            // diagnostic source.
            moxPrint(runShell(
                "/usr/bin/tail",
                "-n", "50",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Mox/daemon.log").path
            ))

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

Task { await runCLI(); exit(0) }
dispatchMain()
