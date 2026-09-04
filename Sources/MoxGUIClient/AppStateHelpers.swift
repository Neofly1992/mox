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
    public static func findMoxServerBinary() -> String {
        // Delegates to `MoxShared.BinaryLocator` so the GUI, the launchd
        // installer, and the process client all share one source of truth
        // for the binary search order.
        if let resolved = BinaryLocator.locate(named: "mox-server") {
            return resolved
        }
        // Last-resort fallback: Process.run() surfaces a clean error.
        return "/opt/homebrew/bin/mox-server"
    }
}

/// v0.10.1 — wraps `HardwareClassifier` + `DefaultModelSuggester` in a
/// single GUI-friendly call. The SwiftUI side calls `current()` and
/// gets back a fully-formed suggestion (hardware detected + tier +
/// ordered recommendations), or a one-liner explanation if the
/// environment is unrecognisable.
///
/// Lives in `MoxGUIClient` (not in the SwiftUI views) so it can be
/// unit-tested without spinning up the GUI host and so the CLI's
/// `handleSuggest` can use the same wrapper if it wants to.
public struct HardwareSuggestion: Sendable, Equatable {
    public let brand: String
    public let totalRAMGB: Int
    public let tier: DefaultModelSuggester.Suggestion.Tier
    public let recommendedIDs: [String]
    /// First id from `recommendedIDs` that the caller reports as
    /// already installed. `nil` when nothing matches.
    public let alreadyInstalled: String?
    public let isAppleSilicon: Bool
    public let notes: String

    public static func current(
        installedModelIDs: [String] = []
    ) -> HardwareSuggestion {
        let hardware = HardwareClassifier()
        let suggestion = DefaultModelSuggester().suggest(for: hardware)
        let installed = installedModelIDs.first(where: suggestion.recommendedIDs.contains)
        return HardwareSuggestion(
            brand: hardware.brandString.isEmpty ? "unknown Mac" : hardware.brandString,
            totalRAMGB: suggestion.totalRAMGB,
            tier: suggestion.tier,
            recommendedIDs: suggestion.recommendedIDs,
            alreadyInstalled: installed,
            isAppleSilicon: hardware.isAppleSilicon,
            notes: suggestion.notes
        )
    }
}
