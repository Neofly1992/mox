import Foundation
import MoxShared

/// Pure helpers backing `MoxGUI.AppState`. Extracted here so the config
/// round-trip and binary-discovery logic can be unit-tested without spinning
/// up SwiftUI. Everything in this file is `@MainActor`-free and runs against
/// a caller-supplied URL — production passes `~/.mox/config.json`, tests
/// pass a temp path.
/// The default `AppConfig` merged with whatever survives in the
/// caller-supplied dictionary. We whitelist the keys AppState manages
/// (`version`, `server`, `defaults`, `defaultSource`, `daemon`) so unrelated
/// fields like `mirrors` and `memory` round-trip through writes unchanged.
public enum MoxGUIConfig {
    public static func serializedConfig(
        host: String,
        port: Int,
        maxTokens: Int,
        temperature: Double,
        daemonEnabled: Bool,
        existing: [String: Any] = [:]
    ) -> [String: Any] {
        var cfg = AppConfig()
        cfg.server.host = host
        cfg.server.port = port
        cfg.defaults.maxTokens = maxTokens
        cfg.defaults.temperature = temperature
        var obj = existing
        // Pull the typed config's encoded form so we keep server/defaults
        // values aligned with the `AppConfig` schema, but only overlay keys
        // we explicitly own — `mirrors` and `memory` would otherwise be
        // wiped to their AppConfig defaults when the user had set them via
        // CLI/manual editing.
        let managedKeys: Set<String> = ["version", "server", "defaults", "defaultSource"]
        if let encoded = try? JSONEncoder().encode(cfg),
           let merged = (try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]) {
            for key in managedKeys {
                if let value = merged[key] { obj[key] = value }
            }
        }
        obj["daemon"] = ["enabled": daemonEnabled]
        return obj
    }

    /// Round-trip test entry point: serializes the fields, pretty-prints, and
    /// writes to `url`. Returns the JSON data so tests can inspect what was
    /// written.
    @discardableResult
    public static func write(
        to url: URL,
        host: String,
        port: Int,
        maxTokens: Int,
        temperature: Double,
        daemonEnabled: Bool,
        existing: [String: Any] = [:]
    ) throws -> Data {
        let obj = serializedConfig(
            host: host,
            port: port,
            maxTokens: maxTokens,
            temperature: temperature,
            daemonEnabled: daemonEnabled,
            existing: existing
        )
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return data
    }

    /// Conventional install locations for `mox-server`. Apple Silicon puts
    /// Homebrew under `/opt/homebrew`, Intel under `/usr/local`; both are
    /// tried, with `mox` (without `-server`) as a less-recommended fallback
    /// for systems that bundle the two binaries into one executable.
    public static let defaultBinaryCandidates: [String] = [
        "/usr/local/bin/mox-server",
        "/opt/homebrew/bin/mox-server",
        "/usr/local/bin/mox",
        "/opt/homebrew/bin/mox",
    ]

    public static func findMoxServerBinary() -> String {
        let fm = FileManager.default
        for path in defaultBinaryCandidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to the conventional first candidate. Spawn will surface
        // a meaningful error if it doesn't actually exist on disk.
        return defaultBinaryCandidates[0]
    }
}
