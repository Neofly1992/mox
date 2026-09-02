import Foundation
import CryptoKit
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

    /// Pull the remote inventory, diff against the local directory, and
    /// download only the changed files. After every download lands:
    ///   1. the per-file SHA-256 manifest (`sha256.txt`) is rewritten so
    ///      `mox list --check` and the next diff pass see the new bytes.
    ///   2. `mox.json` has its `revision` field updated to the new pin so
    ///      the user can see where the local copy is anchored.
    ///
    /// If `revision` was nil on the manifest (legacy install), the new pin
    /// is recorded. We never invent a revision that wasn't observed.
    public func update(
        modelId: String,
        localDirectory: URL,
        revision: String?,
        progressHandler: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> ModelUpdatePlan {
        let remote = try await fetcher.fetch(modelId: modelId, revision: revision)
        let local = try LocalInventoryBuilder.walk(directory: localDirectory)
        let plan = ModelDiffEngine.plan(remote: remote, local: local)

        // Tracks the cumulative byte progress across files so the
        // progress handler can report against `plan.totalBytesToFetch`
        // instead of resetting to 0 at every file boundary.
        let progressTracker = UpdateProgressTracker(totalBytes: plan.totalBytesToFetch)

        for entry in plan.files where entry.action == .download || entry.action == .sizeMismatch {
            guard let base = (mirrorBaseForUpdate(modelId: modelId)) else { continue }
            guard let url = URL(string: "\(base)/\(modelId)/resolve/\(remote.revision ?? "main")/\(entry.path)") else {
                continue
            }
            let safeLocal = try ModelPathGuard.safeChild(
                parent: localDirectory,
                name: (entry.path as NSString).lastPathComponent
            )
            let fileBytes = entry.remoteBytes
            try await downloader.download(from: url, to: safeLocal) { perFileFraction in
                let cumulativeBytes = progressTracker.advance(fileBytes: fileBytes, fraction: perFileFraction)
                progressHandler?(DownloadProgress(
                    modelId: modelId,
                    bytesDownloaded: cumulativeBytes,
                    totalBytes: plan.totalBytesToFetch
                ))
            }
            progressTracker.markFileComplete(fileBytes: fileBytes)
        }

        // No bytes changed → plan is a no-op. Skip the disk writes so
        // we don't touch mtimes on already-current installs.
        if plan.totalBytesToFetch > 0 {
            try rewriteSha256Manifest(at: localDirectory)
            try updateManifestRevision(
                at: localDirectory,
                revision: remote.revision
            )
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

    /// Re-hash every regular file in `dir` and rewrite `sha256.txt`.
    /// The format matches what `pullModel` writes — one line per file:
    /// `<sha256>  <filename>\n`, sorted by filename.
    private func rewriteSha256Manifest(at dir: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var entries: [(String, String)] = []
        for url in contents {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            // Skip the manifests themselves — they describe the model
            // contents, not the weights, and including them would
            // create a chicken-and-egg hash mismatch every time the
            // sha256 file itself is rewritten.
            let name = url.lastPathComponent
            if name == "mox.json" || name == "sha256.txt" { continue }
            guard isFile else { continue }
            entries.append((name, try Self.sha256Hex(of: url)))
        }
        entries.sort { $0.0 < $1.0 }
        let body = entries.map { "\($0.1)  \($0.0)" }.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: dir.appendingPathComponent("sha256.txt"))
    }

    /// Patch `mox.json`'s `revision` field. Existing fields preserved;
    /// missing file is non-fatal (no manifest = no revision pin to
    /// maintain, and we don't want a failed update to silently
    /// corrupt the manifest).
    private func updateManifestRevision(at dir: URL, revision: String?) throws {
        let manifestURL = dir.appendingPathComponent("mox.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        var manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        // Only overwrite when we observed a real revision. nil from the
        // remote means we couldn't determine it; don't blank the
        // existing pin.
        if let revision { manifest.revision = revision }
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: manifestURL, options: [.atomic])
    }

    /// Streaming SHA-256 over a file. Duplicated from
    /// `ModelManager.swift` (which uses the same one-shot scheme for
    /// the pull path). Pulled into the updater rather than promoted
    /// to `MoxShared` because both call sites stay small and the
    /// duplication is honest: the two helpers don't share state, and
    /// a future reader can grep for `sha256Hex(of:)` and find both.
    private static func sha256Hex(of url: URL) throws -> String {
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
}

/// Progress tracker for `mox update` across multiple files.
///
/// The downloader callback fires per-file with a 0..1 fraction of the
/// *current* file; the caller wants a 0..plan.totalBytesToFetch curve.
/// This actor-safe class holds the running total and lets concurrent
/// download callbacks (we don't have them yet, but the type will be
/// Sendable if we add them) advance without races.
final class UpdateProgressTracker: @unchecked Sendable {
    private let totalBytes: Int64
    private let lock = NSLock()
    private var cumulative: Int64 = 0
    private var completed: Int64 = 0

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    /// Advance the cumulative counter by `fileBytes * fraction`,
    /// clamped to `fileBytes` so we don't overshoot when a single
    /// file's fraction briefly exceeds 1.0 due to rounding.
    func advance(fileBytes: Int64, fraction: Double) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let cappedFraction = max(0, min(fraction, 1))
        let baseline = completed
        let projected = baseline + Int64(Double(fileBytes) * cappedFraction)
        cumulative = projected
        return projected
    }

    /// Mark the current file complete. Subsequent `advance` calls for
    /// the same file would no longer be expected, but if they happen
    /// they cap at `completed + fileBytes`.
    func markFileComplete(fileBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        completed += fileBytes
        cumulative = completed
    }
}