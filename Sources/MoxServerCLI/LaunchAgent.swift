import Foundation
import MoxShared

func runShell(_ executable: String, _ arguments: String...) -> String {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

enum LaunchAgent {
    static let label = "com.mox.server"
    static var plistPath: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var configURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mox/config.json") }
    static func binaryPath() -> String { runShell("/usr/bin/uname", "-m").contains("arm64") ? "/opt/homebrew/bin/mox-server" : "/usr/local/bin/mox-server" }
    static func plistData() throws -> Data {
        let dict: [String: Any] = ["Label": label, "ProgramArguments": [binaryPath(), "daemon", "--host", "127.0.0.1", "--port", "11555"], "RunAtLoad": true, "KeepAlive": true, "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mox/daemon.log").path, "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mox/daemon.log").path]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
    static func writeConfig(enabled: Bool) throws {
        let fm = FileManager.default; try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var obj = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: configURL)) ?? Data())) as? [String: Any] ?? [:]
        if let data = try? JSONEncoder().encode(AppConfig()), let base = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = base }
        obj["daemon"] = ["enabled": enabled]
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)
    }
    static func install() throws {
        let fm = FileManager.default; try fm.createDirectory(at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.createDirectory(at: plistPath.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Logs/Mox"), withIntermediateDirectories: true)
        try plistData().write(to: plistPath); try writeConfig(enabled: true)
        print("Installed \(plistPath.path) (launchctl load skipped)")
    }
    static func uninstall() throws { try? writeConfig(enabled: false); try? FileManager.default.removeItem(at: plistPath); print("Uninstalled \(label)") }
}
