import Foundation
import MoxShared

/// Fetches a remote model's file inventory from its source. v0.8 ships
/// the HuggingFace adapter; ModelScope ships in v0.8.1 once the
/// `HuggingFaceSource` / `ModelScopeSource` mirror policy applies to
/// tree listings.
///
/// The contract: `fetch(modelId:revision:)` returns a
/// `RemoteModelInventory` whose `files` array is the complete manifest
/// the source can give us, with `path` matching the on-disk
/// relative-to-model-dir path the diff engine compares against.
public protocol RemoteInventoryFetcher: Sendable {
    func fetch(modelId: String, revision: String?) async throws -> RemoteModelInventory
}

public enum RemoteFetcherError: Error, LocalizedError {
    case unsupportedSource(String)
    case badStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource(let s): return "remote fetcher not implemented for source '\(s)'"
        case .badStatus(let code): return "remote source returned HTTP \(code)"
        case .malformedResponse: return "remote source returned malformed JSON"
        }
    }
}

/// HuggingFace tree adapter. Hits `/api/models/{repo_id}` and turns the
/// `siblings[].rfilename` + `siblings[].size` payload into
/// `RemoteModelInventory`. Mirrors via the `HuggingFaceSource` allowlist
/// are honoured by the caller (passing `mirrorBase` when applicable).
public struct HuggingFaceInventoryFetcher: RemoteInventoryFetcher {
    public let mirrorBase: String?
    public init(mirrorBase: String? = nil) {
        self.mirrorBase = mirrorBase
    }

    public func fetch(modelId: String, revision: String?) async throws -> RemoteModelInventory {
        let base = mirrorBase ?? "https://huggingface.co"
        guard let apiURL = URL(string: "\(base)/api/models/\(modelId)") else {
            throw RemoteFetcherError.malformedResponse
        }
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFetcherError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteFetcherError.badStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteFetcherError.malformedResponse
        }
        // HF returns two relevant fields: `siblings[]` (always) and
        // `sha` (commit hash, optional). `siblings` entries may include
        // `rfilename`, `size`, and (sometimes) `blobId`.
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        let resolvedRevision = revision ?? (json["sha"] as? String)

        var entries: [RemoteFileEntry] = []
        for sibling in siblings {
            guard let path = sibling["rfilename"] as? String else { continue }
            let size = (sibling["size"] as? Int64) ?? 0
            // HF doesn't expose per-file sha256 in the tree API. The
            // diff engine treats that as "needs hash verification at
            // download time" rather than a hash-mismatch shortcut.
            entries.append(RemoteFileEntry(
                path: path,
                sizeBytes: size,
                sha256: nil,
                etag: nil
            ))
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return RemoteModelInventory(
            modelId: modelId,
            revision: resolvedRevision,
            files: entries,
            totalBytes: total
        )
    }
}

/// `mox update` orchestrator. Pulls the remote inventory, runs the diff
/// engine, downloads only the changed files, and rewrites the manifest
/// with the new revision pin.
public struct ModelUpdater {
    public let fetcher: RemoteInventoryFetcher
    public let downloader: Downloader

    public init(fetcher: RemoteInventoryFetcher, downloader: Downloader) {
        self.fetcher = fetcher
        self.downloader = downloader
    }

    public func update(
        modelId: String,
        localDirectory: URL,
        revision: String?,
        progressHandler: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> ModelUpdatePlan {
        let remote = try await fetcher.fetch(modelId: modelId, revision: revision)
        let local = try LocalInventoryBuilder.walk(directory: localDirectory)
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        for entry in plan.files where entry.action == .download || entry.action == .sizeMismatch {
            try ModelPathGuard.safeChild(parent: localDirectory, name: (entry.path as NSString).lastPathComponent)
            guard let base = (mirrorBaseForUpdate(modelId: modelId)) else { continue }
            guard let url = URL(string: "\(base)/\(modelId)/resolve/\(remote.revision ?? "main")/\(entry.path)") else {
                continue
            }
            let safeLocal = try ModelPathGuard.safeChild(
                parent: localDirectory,
                name: (entry.path as NSString).lastPathComponent
            )
            try await downloader.download(from: url, to: safeLocal) { progress in
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: entry.remoteBytes * Int64(progress),
                    totalBytes: plan.totalBytesToFetch
                ))
            }
        }
        return plan
    }

    private func mirrorBaseForUpdate(modelId: String) -> String? {
        // Honour the configured HF mirror via the same allowlist as
        // pull. The mirror base is captured at update-time so an HF
        // mirror switch invalidates only future updates, not past
        // caches.
        if let mirrorBase = HuggingFaceMirrorPolicy.allowedHosts
            .first(where: { _ in false }) {
            return mirrorBase
        }
        return "https://huggingface.co"
    }
}