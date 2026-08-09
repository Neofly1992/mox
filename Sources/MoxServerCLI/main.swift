import Foundation
import MoxServer

func help() { print("mox-server commands: daemon install uninstall start stop status logs") }
func value(_ args: [String], _ name: String, _ fallback: String) -> String { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }; return args[i + 1] }
func runCLI() async {
 let args = CommandLine.arguments
 guard args.count > 1 else { help(); return }
 do {
  switch args[1] {
  case "daemon":
   let host = value(args, "--host", "127.0.0.1"); let port = Int(value(args, "--port", "11555")) ?? 11555
   let server = MoxServer(host: host, port: port); try server.start(); print("Mox server listening on \(host):\(port)"); dispatchMain()
  case "install": try LaunchAgent.install()
  case "uninstall": try LaunchAgent.uninstall()
  case "start": print(runShell("/bin/launchctl", "start", LaunchAgent.label))
  case "stop": print(runShell("/bin/launchctl", "stop", LaunchAgent.label))
  case "status": let out = runShell("/bin/launchctl", "list"); print(out.contains(LaunchAgent.label) ? out : "not loaded")
  case "logs": print(runShell("/usr/bin/tail", "-n", "50", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mox/daemon.log").path))
  case "help", "--help", "-h": help()
  default: help()
  }
 } catch { fputs("error: \(error)\n", stderr); exit(1) }
}
Task { await runCLI(); exit(0) }
dispatchMain()
