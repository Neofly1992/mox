// Standalone smoke driver for MoxGUI startup scenarios. Compile via the
// build_mox_gui_smoke shell script. Exercises the same config-decision
// logic AppState.bootstrap runs, without booting SwiftUI.

import Foundation
import MoxGUIClient

@main
struct MoxGUISmoke {
    static func main() async {
        let scenarioName = ProcessInfo.processInfo.environment["MOX_SMOKE_SCENARIO"]
            ?? "missing-MOX_SMOKE_SCENARIO"
        let scenarios: [(String, Bool, Bool)] = [
            ("daemon-running",              true,  true),
            ("daemon-not-running-disabled", false, false),
            ("daemon-not-running-enabled",  false, true),
        ]
        guard let s = scenarios.first(where: { $0.0 == scenarioName }) else {
            print("Unknown scenario: \(scenarioName). Expected: \(scenarios.map(\.0).joined(separator: ", "))")
            exit(2)
        }
        let (_, daemonReachable, daemonEnabled) = s
        print("=== MoxGUI startup smoke ===")
        print("scenario:        \(scenarioName)")
        print("daemonReachable: \(daemonReachable)")
        print("daemonEnabled:   \(daemonEnabled)")

        // Step 1: write a config like the Settings picker would.
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-smoke-\(UUID().uuidString)/.mox")
        try? FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true
        )
        let configURL = configDir.appendingPathComponent("config.json")
        do {
            _ = try MoxGUIConfig.write(
                to: configURL,
                host: "127.0.0.1",
                port: 11555,
                maxTokens: 2048,
                temperature: 0.7,
                daemonEnabled: daemonEnabled,
                existing: [:]
            )
        } catch {
            print("write failed: \(error)")
            exit(1)
        }
        let raw = (try? JSONSerialization.jsonObject(
            with: try Data(contentsOf: configURL)
        ) as? [String: Any]) ?? [:]
        let writtenJson = (try? JSONSerialization.data(
            withJSONObject: raw,
            options: [.prettyPrinted, .sortedKeys]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("config.json on disk:\n\(writtenJson)")

        // Step 2: probe /health on the server URL.
        let probeURL = URL(string: "http://127.0.0.1:11555/health")!
        var req = URLRequest(url: probeURL)
        req.timeoutInterval = 0.5
        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            reachable = (response as? HTTPURLResponse)
                .map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            reachable = false
        }
        print("probe 127.0.0.1:11555/health: reachable=\(reachable)")

        // Step 3: mode decision (mirrors AppState.bootstrap).
        let mode: String
        let statusBar: String
        let dialog: Bool
        if reachable {
            mode = "daemon"
            statusBar = "activates (HTTPAPIClient + menu bar)"
            dialog = false
        } else if daemonEnabled {
            mode = "awaiting user choice"
            statusBar = "dormant until user picks Start / Temporary / Cancel"
            dialog = true
        } else {
            mode = "temporary"
            statusBar = "dormant (no menu bar in temporary mode)"
            dialog = false
        }
        print("decision: mode=\(mode)")
        print("          StatusBarController=\(statusBar)")
        print("          DaemonModeDialog.show=\(dialog)")

        try? FileManager.default.removeItem(
            at: configURL.deletingLastPathComponent().deletingLastPathComponent()
        )
    }
}
