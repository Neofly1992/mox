import Foundation
import MoxShared

/// Persists `AppConfig` to `~/.mox/config.json`. Reading and writing the same
/// JSON file from concurrent tasks would race, so we isolate the I/O behind a
/// Swift 6 `actor`: every access to disk happens serially on the actor's
/// executor with no explicit locking.
public actor ConfigManager {
    public static let shared = ConfigManager()

    private let configPath: String

    public init(configPath: String? = nil) {
        if let path = configPath {
            self.configPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.configPath = "\(home)/.mox/config.json"
        }
    }

    public func load() throws -> AppConfig {
        let fileURL = URL(fileURLWithPath: configPath)

        guard FileManager.default.fileExists(atPath: configPath) else {
            let config = AppConfig()
            try save(config)
            return config
        }

        return try Self.decodeOrFallback(fileURL: fileURL, logLabel: "load")
    }

    /// Decodes `AppConfig` from `fileURL`, falling back to defaults
    /// (and quarantining the corrupt file to `<path>.bak`) if the JSON is
    /// unparseable. Avoids bricking the GUI when a hand-edited config is
    /// out of sync with the typed schema.
    private static func decodeOrFallback(fileURL: URL, logLabel: String) throws -> AppConfig {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            let backupURL = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            moxLog.error("\(logLabel, privacy: .public) config decode failed (\(String(describing: error), privacy: .public)); quarantined to \(backupURL.path, privacy: .public)")
            return AppConfig()
        }
    }


    public func save(_ config: AppConfig) throws {
        let fileURL = URL(fileURLWithPath: configPath)
        let directory = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func update(_ transform: (inout AppConfig) -> Void) throws {
        var config = try load()
        transform(&config)
        try save(config)
    }

    /// Synchronous read for callers that cannot await the actor. Used by
    /// launchd-install paths and the GUI bootstrap where we want to fail fast
    /// without spinning up a Swift concurrency context. Reads the file once;
    /// does NOT write a default back if the file is absent — the caller
    /// decides whether to seed one.
    public nonisolated func loadSync() throws -> AppConfig {
        let fileURL = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: configPath) else {
            return AppConfig()
        }
        return try Self.decodeOrFallback(fileURL: fileURL, logLabel: "loadSync")
    }

    /// Synchronous save for the same set of callers. Same atomic-write
    /// contract as the actor-isolated `save`, exposed for the install
    /// path which must complete before returning control to the shell.
    public nonisolated func saveSync(_ config: AppConfig) throws {
        let fileURL = URL(fileURLWithPath: configPath)
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
    }


}