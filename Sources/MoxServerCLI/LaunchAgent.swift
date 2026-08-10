import Foundation
import MoxCore
import MoxShared

func runShell(_ executable: String, _ arguments: String...) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        moxServerLog.error("runShell \(executable, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

enum LaunchAgent {
    static let label = "com.mox.server"

    static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mox/config.json")
    }

    static func binaryPath() -> String {
        runShell("/usr/bin/uname", "-m").contains("arm64")
            ? "/opt/homebrew/bin/mox-server"
            : "/usr/local/bin/mox-server"
    }

    static func plistData() throws -> Data {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mox").path
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath(), "daemon", "--host", "127.0.0.1", "--port", "11555"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "\(logDir)/daemon.log",
            "StandardErrorPath": "\(logDir)/daemon.log",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func writeConfig(enabled: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var obj: [String: Any] = [:]
        // If the file exists, preserve everything the user already had
        // (mirrors, memory.reservePercent, defaultSource, etc.) and only
        // patch the daemon flag. If the file is missing, seed with
        // AppConfig() defaults so a fresh install isn't an empty object.
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        } else if let data = try? JSONEncoder().encode(AppConfig()),
                  let base = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = base
        }
        obj["daemon"] = ["enabled": enabled]

        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL)
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mox")
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        try plistData().write(to: plistPath)
        try writeConfig(enabled: true)

        moxPrint("Installed \(plistPath.path) (launchctl load skipped)")
        moxServerLog.info("launchd plist installed at \(plistPath.path, privacy: .public)")
    }

    static func uninstall() throws {
        try? writeConfig(enabled: false)
        try? FileManager.default.removeItem(at: plistPath)

        moxPrint("Uninstalled \(label)")
        moxServerLog.info("launchd plist removed for \(label, privacy: .public)")
    }
}
