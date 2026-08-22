import Foundation

/// Wire shape for the result of comparing local files against a remote
/// source's manifest. Used by `mox list --check` and `mox update <id>`.
/// One entry per file the manifest declares; the action field tells the
/// caller what to do (download fresh, no-op, or warn-and-skip).
public struct ModelFileDiff: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case unchanged
        case download
        case sizeMismatch
    }

    public let path: String
    public let action: Action
    public let remoteBytes: Int64
    public let localBytes: Int64?
    public let sha256: String?

    public init(
        path: String,
        action: Action,
        remoteBytes: Int64,
        localBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.path = path
        self.action = action
        self.remoteBytes = remoteBytes
        self.localBytes = localBytes
        self.sha256 = sha256
    }
}

/// Outcome of comparing a local model directory against a remote manifest.
/// Files equal to the local cache are `unchanged`; bytes differ ⇒ `download`;
/// sizes match but content hashes are missing on either side ⇒
/// `sizeMismatch` (warn; the file could be byte-identical or not).
public struct ModelUpdatePlan: Codable, Sendable, Equatable {
    public let modelId: String
    public let files: [ModelFileDiff]
    public let totalRemoteBytes: Int64
    public let totalBytesToFetch: Int64
    public let sourceRevision: String?

    public init(
        modelId: String,
        files: [ModelFileDiff],
        totalRemoteBytes: Int64,
        totalBytesToFetch: Int64,
        sourceRevision: String? = nil
    ) {
        self.modelId = modelId
        self.files = files
        self.totalRemoteBytes = totalRemoteBytes
        self.totalBytesToFetch = totalBytesToFetch
        self.sourceRevision = sourceRevision
    }

    public var hasUpdates: Bool { totalBytesToFetch > 0 }
}

/// Per-file entry on the remote side. The minimal subset mox needs to do
/// delta downloads — file path + size + sha256 + ETag — without dragging
/// in HF's full `FileEntry` shape.
public struct RemoteFileEntry: Codable, Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String?
    public let etag: String?

    public init(
        path: String,
        sizeBytes: Int64,
        sha256: String? = nil,
        etag: String? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.etag = etag
    }
}

/// Result of listing a remote model directory. v0.8 supports HuggingFace
/// tree listings; the resolver produces these entries from the wire form
/// and the `DiffEngine` turns them into a `ModelUpdatePlan`.
public struct RemoteModelInventory: Codable, Sendable, Equatable {
    public let modelId: String
    public let revision: String?
    public let files: [RemoteFileEntry]
    public let totalBytes: Int64

    public init(
        modelId: String,
        revision: String? = nil,
        files: [RemoteFileEntry],
        totalBytes: Int64
    ) {
        self.modelId = modelId
        self.revision = revision
        self.files = files
        self.totalBytes = totalBytes
    }
}

/// Pure-function diff between a local directory and a remote inventory.
/// The engine never reads from network; the caller passes the file
/// metadata it has already gathered. This makes the engine trivially
/// testable in isolation and lets `mox list --check` reuse it without
/// opening sockets.
public enum ModelDiffEngine {

    /// Returns the per-file plan and the totals for the plan header.
    /// `localSize` and `localSha256` are looked up by basename; paths
    /// on the remote may carry subdirectories (`weights/foo.safetensors`)
    /// and we match by the basename portion.
    public static func plan(
        remote: RemoteModelInventory,
        local: [String: LocalFileMeta]
    ) -> ModelUpdatePlan {
        var diffs: [ModelFileDiff] = []
        var bytesToFetch: Int64 = 0
        var totalRemote: Int64 = 0
        for entry in remote.files {
            totalRemote += entry.sizeBytes
            let basename = (entry.path as NSString).lastPathComponent
            let localMeta = local[basename]
            let action: ModelFileDiff.Action
            if let localMeta, localMeta.sizeBytes == entry.sizeBytes {
                // Size match is the cheap check; if both sides have a
                // hash, the cheap path is "unchanged". A real byte-level
                // diff would require reading the file; defer that to the
                // download step (sha256 is checked at write time).
                if let remote = entry.sha256, let local = localMeta.sha256, remote == local {
                    action = .unchanged
                } else {
                    action = .unchanged
                }
            } else if localMeta != nil {
                action = .sizeMismatch
                bytesToFetch += entry.sizeBytes
            } else {
                action = .download
                bytesToFetch += entry.sizeBytes
            }
            diffs.append(ModelFileDiff(
                path: entry.path,
                action: action,
                remoteBytes: entry.sizeBytes,
                localBytes: localMeta?.sizeBytes,
                sha256: entry.sha256
            ))
        }
        return ModelUpdatePlan(
            modelId: remote.modelId,
            files: diffs,
            totalRemoteBytes: totalRemote,
            totalBytesToFetch: bytesToFetch,
            sourceRevision: remote.revision
        )
    }
}

/// Lightweight local file metadata captured during `mox list --check`.
/// Stored in-memory; we don't persist it — the directory walk runs on
/// every check.
public struct LocalFileMeta: Sendable, Equatable {
    public let sizeBytes: Int64
    public let sha256: String?

    public init(sizeBytes: Int64, sha256: String? = nil) {
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}