import Foundation
import MoxShared

public final class ConfigManager: @unchecked Sendable {
    public static let shared = ConfigManager()
    
    private let configPath: String
    private var cachedConfig: AppConfig?
    private let queue = DispatchQueue(label: "com.mox.config", attributes: .concurrent)
    
    public init(configPath: String? = nil) {
        if let path = configPath {
            self.configPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.configPath = "\(home)/.mox/config.json"
        }
    }
    
    public func load() throws -> AppConfig {
        return try queue.sync {
            if let cached = cachedConfig {
                return cached
            }
            
            let fileURL = URL(fileURLWithPath: configPath)
            
            guard FileManager.default.fileExists(atPath: configPath) else {
                let config = AppConfig()
                try save(config)
                cachedConfig = config
                return config
            }
            
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let config = try decoder.decode(AppConfig.self, from: data)
            cachedConfig = config
            return config
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
        let data = try encoder.encode(config)
        try data.write(to: fileURL)
        
        queue.async(flags: .barrier) {
            self.cachedConfig = config
        }
    }
    
    public func update(_ transform: (inout AppConfig) -> Void) throws {
        var config = try load()
        transform(&config)
        try save(config)
    }
}
