import Foundation
import CryptoKit
import MoxShared

/// Safely joins a single path component onto a parent URL. Rejects names that
/// would escape the parent (empty, absolute, `..`, containing path separators,
/// or anything that does not resolve to a direct child of the parent).
///
/// Used to defend against path traversal when a remote server returns a
/// malicious file name (e.g. HuggingFace/ModelScope `rfilename` / `Name`).
enum ModelPathGuard {
    static func safeChild(parent: URL, name: String) throws -> URL {
        guard !name.isEmpty else {
            throw ModelError.invalidFileName(name)
        }
        if name.hasPrefix("/") || name.hasPrefix("~") {
            throw ModelError.invalidFileName(name)
        }
        if name.contains("..") {
            throw ModelError.invalidFileName(name)
        }
        if name.contains("/") || name.contains("\\") {
            throw ModelError.invalidFileName(name)
        }
        let candidate = parent.appending(path: name).standardizedFileURL
        let parentStandardized = parent.standardizedFileURL
        // URL.appending(path:) percent-encodes characters that don't round-trip
        // (e.g. spaces -> %20), so we cannot require an exact string match.
        // Instead, require: (a) candidate path starts with parent's path,
        // (b) candidate has exactly one more path component than parent,
        // (c) the last component is the *decoded* name.
        let parentPath = parentStandardized.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let parentComponents = parentStandardized.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidate.path.hasPrefix(parentPrefix),
              candidateComponents.count == parentComponents.count + 1,
              candidateComponents.last == name else {
            throw ModelError.invalidFileName(name)
        }
        return candidate
    }
}

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

                let size = try calculateDirectorySize(at: modelDir)
                let modDate = (try? modelDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                let manifestURL = modelDir.appendingPathComponent("mox.json")
                let info: ModelInfo
                if let manifestData = try? Data(contentsOf: manifestURL),
                   let manifest = try? JSONDecoder().decode(ModelManifest.self, from: manifestData) {
                    info = ModelInfo(
                        id: manifest.id,
                        name: manifest.id,
                        source: manifest.source,
                        path: modelDir.path,
                        size: size,
                        lastUsed: modDate
                    )
                } else {
                    // Legacy / foreign model directories (no manifest): surface
                    // as `unknown` instead of fabricating a source guess.
                    info = ModelInfo(
                        id: modelDir.lastPathComponent,
                        name: modelDir.lastPathComponent,
                        source: .unknown,
                        path: modelDir.path,
                        size: size,
                        lastUsed: modDate
                    )
                }
                models.append(info)
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
        // Resolve any configured mirror once and validate against the source's
        // host allowlist before we touch the network.
        let config = try? ConfigManager.shared.load()
        let resolvedId: String

        switch source {
        case .huggingface:
            let mirror = config?.mirrors.huggingface
            let hfSource = try makeHuggingFaceSource(mirror: mirror)
            resolvedId = hfSource.resolveModelId(id)
        case .modelscope:
            let mirror = config?.mirrors.modelscope
            let msSource = try makeModelScopeSource(mirror: mirror)
            resolvedId = msSource.resolveModelId(id)
        case .mlxCommunity:
            // Reuse HuggingFaceSource so the namespace prefix is applied
            // exactly once. Previously this code prefixed "mlx-community/" on
            // top of HuggingFaceSource.resolveModelId, which itself prepends
            // "mlx-community/" for ids without a `/`, producing the double
            // prefix "mlx-community/mlx-community/<id>".
            let mirror = config?.mirrors.huggingface
            let hfSource = try makeHuggingFaceSource(mirror: mirror)
            resolvedId = hfSource.resolveModelId(id)
        case .unknown:
            // `unknown` is reserved for directories pre-dating the manifest
            // format; pulling with it is not a supported operation.
            throw ModelError.invalidPath(source.rawValue)
        }

        // The model id itself is a path component (we derive a directory name
        // from it). Validate before we let it touch the filesystem.
        let sanitizedId = resolvedId.replacingOccurrences(of: "/", with: "-")
        _ = try ModelPathGuard.safeChild(parent: modelsDirectory, name: sanitizedId)
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
            case .unknown:
                throw ModelError.invalidPath(source.rawValue)
            }

            // Validate every file name produced by the remote before moving
            // anything. The source API is trusted-but-verified: even if
            // HF/ModelScope return malicious paths today, we refuse to write
            // outside the model directory.
            // Compute SHA-256 over every downloaded file *while it still lives
            // in the temp directory*. If hashing fails we abort before any
            // bytes reach `destinationDir`, so a partial install cannot end
            // up looking like a complete one.
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            var shaEntries: [(String, String)] = [] // (relativePath, sha256)
            for item in contents {
                let hash = try sha256Hex(of: item)
                shaEntries.append((item.lastPathComponent, hash))
            }
            shaEntries.sort { $0.0 < $1.0 }

            // Now that every file is verified, validate the file name and
            // move into `destinationDir` under guard so a traversal
            // rejection cannot leave orphaned bytes behind.
            for item in contents {
                let safeDest = try ModelPathGuard.safeChild(parent: destinationDir, name: item.lastPathComponent)
                try FileManager.default.moveItem(at: item, to: safeDest)
            }

            // Write sha256 manifest first so the file is always present even
            // if the mox.json write below fails for any reason.
            try writeSha256Manifest(at: destinationDir, entries: shaEntries)

            // Write mox.json so `listModels` and `modelInfo(for:)` can recover
            // the source without reverse-engineering the directory name.
            let manifest = ModelManifest(id: resolvedId, source: source, originalId: id)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: destinationDir.appendingPathComponent("mox.json"))

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
            // Validate the file name BEFORE using it in any URL or path. A
            // malicious or compromised mirror could return "../../etc/passwd"
            // here, and we want to refuse rather than leak the request or
            // write outside `destination`.
            let safeLocalURL = try ModelPathGuard.safeChild(parent: destination, name: file)

            // Build the remote URL only after the local URL passes guard.
            guard let fileURL = URL(string: "\(base)/\(modelId)/resolve/main/\(file)") else {
                throw ModelError.invalidFileName(file)
            }

            try await downloader.download(from: fileURL, to: safeLocalURL) { progress in
                let incremental = Int64(Double(totalSize) * progress / Double(files.count))
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: downloadedSize + incremental,
                    totalBytes: totalSize
                ))
            }

            let fileSize = try FileManager.default.attributesOfItem(atPath: safeLocalURL.path)[.size] as? Int64 ?? 0
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
        // Sum advertised sizes up front so progress reports meaningful
        // bytes (not a file count) like `downloadFromHuggingFace` does.
        let totalSize = files.reduce(Int64(0)) { $0 + Int64($1["Size"] as? Int ?? 0) }
        var downloadedSize: Int64 = 0

        for fileInfo in files {
            guard let fileName = fileInfo["Name"] as? String else { continue }
            let declaredSize = Int64(fileInfo["Size"] as? Int ?? 0)

            // Validate before touching the URL or filesystem.
            let safeLocalURL = try ModelPathGuard.safeChild(parent: destination, name: fileName)

            // ModelScope exposes the raw file via a query parameter. The
            // server-side check is the only thing standing between us and a
            // file-injection; we still guard the URL by percent-encoding the
            // query value.
            var components = URLComponents(string: "\(base)/\(namespace)/\(name)/raw")
            components?.queryItems = [URLQueryItem(name: "FilePath", value: fileName)]
            guard let fileURL = components?.url else {
                throw ModelError.invalidFileName(fileName)
            }

            let fileProgress: ((Double) -> Void)? = { progress in
                let bytesSoFar = downloadedSize + Int64(Double(declaredSize) * progress)
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: bytesSoFar,
                    totalBytes: totalSize
                ))
            }

            try await downloader.download(from: fileURL, to: safeLocalURL, progress: fileProgress)

            let fileSize = try FileManager.default.attributesOfItem(atPath: safeLocalURL.path)[.size] as? Int64 ?? 0
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

    /// Build a HuggingFaceSource using the configured mirror only when one is
    /// non-empty. Avoids the `try` warning that surfaces when the closure
    /// only throws in one branch.
    private func makeHuggingFaceSource(mirror: String?) throws -> HuggingFaceSource {
        if let m = mirror, !m.isEmpty {
            return try HuggingFaceSource(mirror: m)
        }
        return try HuggingFaceSource()
    }

    /// Same as above for ModelScopeSource.
    private func makeModelScopeSource(mirror: String?) throws -> ModelScopeSource {
        if let m = mirror, !m.isEmpty {
            return try ModelScopeSource(mirror: m)
        }
        return try ModelScopeSource()
    }
}

// MARK: - SHA256 helpers

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while autoreleasepool(invoking: { () -> Bool in
        let chunk = handle.readData(ofLength: 1 << 20) // 1 MiB
        if chunk.isEmpty { return false }
        hasher.update(data: chunk)
        return true
    }) {}
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func writeSha256Manifest(at dir: URL, entries: [(String, String)]) throws {
    let body = entries.map { "\($0.1)  \($0.0)" }.joined(separator: "\n") + "\n"
    try Data(body.utf8).write(to: dir.appendingPathComponent("sha256.txt"))
}

public enum ModelError: Error, LocalizedError {
    case notFound(String)
    case alreadyExists(String)
    case invalidPath(String)
    case invalidFileName(String)
    case invalidMirror(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Model '\(id)' not found"
        case .alreadyExists(let id):
            return "Model '\(id)' already exists"
        case .invalidPath(let path):
            return "Invalid model path: \(path)"
        case .invalidFileName(let name):
            return "Invalid file name rejected by path guard: '\(name)'"
        case .invalidMirror(let mirror):
            return "Mirror host not on allowlist: '\(mirror)'"
        }
    }
}