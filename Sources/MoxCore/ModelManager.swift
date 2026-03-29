import Foundation
import MoxShared

public final class ModelManager: @unchecked Sendable {
    public static let shared = ModelManager()
    
    private let modelsDirectory: URL
    private let queue = DispatchQueue(label: "com.mox.modelmanager", attributes: .concurrent)
    private var cachedModels: [String: ModelInfo]?
    
    public init(modelsDirectory: String? = nil) {
        if let dir = modelsDirectory {
            self.modelsDirectory = URL(fileURLWithPath: dir)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.modelsDirectory = URL(fileURLWithPath: "\(home)/.mox/models")
        }
        
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
    }
    
    public func listModels() throws -> [ModelInfo] {
        return try queue.sync {
            if let cached = cachedModels {
                return Array(cached.values).sorted { $0.name < $1.name }
            }
            
            var models: [ModelInfo] = []
            
            guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
                return models
            }
            
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelsDirectory,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            for modelDir in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }
                
                let modelId = modelDir.lastPathComponent
                let parts = modelId.components(separatedBy: "-")
                let source: ModelSource = parts.first == "mlxcommunity" ? .mlxCommunity : .huggingface
                
                let size = try calculateDirectorySize(at: modelDir)
                let modDate = try modelDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                
                let modelInfo = ModelInfo(
                    id: modelId,
                    name: modelId,
                    source: source,
                    path: modelDir.path,
                    size: size,
                    lastUsed: modDate
                )
                models.append(modelInfo)
            }
            
            var newCache: [String: ModelInfo] = [:]
            for model in models {
                newCache[model.id] = model
            }
            cachedModels = newCache
            
            return models.sorted { $0.name < $1.name }
        }
    }
    
    public func modelInfo(for id: String) throws -> ModelInfo? {
        return try listModels().first { $0.id == id }
    }
    
    public func modelPath(for id: String) throws -> URL {
        guard let info = try modelInfo(for: id) else {
            throw ModelError.notFound(id)
        }
        return URL(fileURLWithPath: info.path)
    }
    
    public func deleteModel(id: String) throws {
        let path = try modelPath(for: id)
        
        try FileManager.default.removeItem(at: path)
        
        queue.async(flags: .barrier) {
            self.cachedModels?.removeValue(forKey: id)
        }
    }
    
    public func pullModel(
        id: String,
        source: ModelSource,
        progressHandler: ((DownloadProgress) -> Void)? = nil
    ) async throws -> ModelInfo {
        let registry = SourceRegistry.shared
        let resolvedId: String
        
        switch source {
        case .huggingface:
            let hfSource = HuggingFaceSource()
            resolvedId = hfSource.resolveModelId(id)
        case .modelscope:
            let msSource = ModelScopeSource()
            resolvedId = msSource.resolveModelId(id)
        case .mlxCommunity:
            let hfSource = HuggingFaceSource()
            resolvedId = "mlx-community/\(hfSource.resolveModelId(id))"
        }
        
        let sanitizedId = resolvedId.replacingOccurrences(of: "/", with: "-")
        let destinationDir = modelsDirectory.appendingPathComponent(sanitizedId)
        
        if FileManager.default.fileExists(atPath: destinationDir.path) {
            throw ModelError.alreadyExists(resolvedId)
        }
        
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        
        let tempDir = modelsDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        do {
            switch source {
            case .huggingface, .mlxCommunity:
                try await downloadFromHuggingFace(
                    modelId: resolvedId,
                    destination: tempDir,
                    progressHandler: progressHandler
                )
            case .modelscope:
                try await downloadFromModelScope(
                    modelId: resolvedId,
                    destination: tempDir,
                    progressHandler: progressHandler
                )
            }
            
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for item in contents {
                let dest = destinationDir.appendingPathComponent(item.lastPathComponent)
                try FileManager.default.moveItem(at: item, to: dest)
            }
            
            let size = try calculateDirectorySize(at: destinationDir)
            let modelInfo = ModelInfo(
                id: resolvedId,
                name: resolvedId,
                source: source,
                path: destinationDir.path,
                size: size,
                lastUsed: nil
            )
            
            queue.async(flags: .barrier) {
                self.cachedModels?[resolvedId] = modelInfo
            }
            
            return modelInfo
        } catch {
            try? FileManager.default.removeItem(at: destinationDir)
            throw error
        }
    }
    
    private func downloadFromHuggingFace(
        modelId: String,
        destination: URL,
        progressHandler: ((DownloadProgress) -> Void)?
    ) async throws {
        let base = "https://huggingface.co"
        let apiURL = URL(string: "\(base)/api/models/\(modelId)")!
        
        let downloader = ResumableDownloader()
        
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.networkError("Failed to fetch model info")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw DownloadError.networkError("Invalid response format")
        }
        
        let files = siblings.compactMap { $0["rfilename"] as? String }
        let totalSize = siblings.reduce(Int64(0)) { $0 + ($1["size"] as? Int64 ?? 0) }
        
        var downloadedSize: Int64 = 0
        
        for file in files {
            let fileURL = URL(string: "\(base)/\(modelId)/resolve/main/\(file)")!
            let localURL = destination.appendingPathComponent(file)
            
            try await downloader.download(from: fileURL, to: localURL) { progress in
                let incremental = Int64(Double(totalSize) * progress / Double(files.count))
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: downloadedSize + incremental,
                    totalBytes: totalSize
                ))
            }
            
            let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64 ?? 0
            downloadedSize += fileSize
        }
    }
    
    private func downloadFromModelScope(
        modelId: String,
        destination: URL,
        progressHandler: ((DownloadProgress) -> Void)?
    ) async throws {
        let base = "https://modelscope.cn/api/v1/models"
        let parts = modelId.split(separator: "/")
        guard parts.count >= 2 else {
            throw DownloadError.invalidModelId
        }
        let namespace = String(parts[0])
        let name = String(parts[1])
        
        let infoURL = URL(string: "\(base)/\(namespace)/\(name)")!
        let (data, _) = try await URLSession.shared.data(from: infoURL)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data_ = json["Data"] as? [String: Any],
              let files = data_["Files"] as? [[String: Any]] else {
            throw DownloadError.networkError("Failed to fetch ModelScope model info")
        }
        
        let downloader = ResumableDownloader()
        let totalFiles = files.count
        var downloadedSize: Int64 = 0
        var currentFile = 0
        
        for fileInfo in files {
            guard let fileName = fileInfo["Name"] as? String else { continue }
            
            let fileURL = URL(string: "\(base)/\(namespace)/\(name)/raw?FilePath=\(fileName)")!
            let localURL = destination.appendingPathComponent(fileName)
            
            currentFile += 1
            let fileProgress: ((Double) -> Void)? = { progress in
                let overall = (Double(downloadedSize) + Double(fileInfo["Size"] as? Int ?? 0) * progress) / Double(totalFiles)
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: Int64(overall),
                    totalBytes: Int64(totalFiles)
                ))
            }
            
            try await downloader.download(from: fileURL, to: localURL, progress: fileProgress)
            
            let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64 ?? 0
            downloadedSize += fileSize
        }
    }
    
    private func calculateDirectorySize(at url: URL) throws -> Int64 {
        var size: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            size += Int64(fileSize)
        }
        
        return size
    }
    
    public func invalidateCache() {
        queue.async(flags: .barrier) {
            self.cachedModels = nil
        }
    }
}

public enum ModelError: Error, LocalizedError {
    case notFound(String)
    case alreadyExists(String)
    case invalidPath(String)
    
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Model '\(id)' not found"
        case .alreadyExists(let id):
            return "Model '\(id)' already exists"
        case .invalidPath(let path):
            return "Invalid model path: \(path)"
        }
    }
}
