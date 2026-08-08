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

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        let fileURL = URL(fileURLWithPath: configPath)
        let directory = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: fileURL)
    }

    public func update(_ transform: (inout AppConfig) -> Void) throws {
        var config = try load()
        transform(&config)
        try save(config)
    }
}