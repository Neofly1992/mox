import Foundation
import MoxShared

/// Walks a model directory on disk and produces a `[basename: LocalFileMeta]`
/// suitable for the diff engine. v0.8 uses this for `mox list --check` —
/// it doesn't talk to the network, just records sizes for the files that
/// already exist locally. Future revisions can layer a remote probe on top
/// to compare against the source.
public enum LocalInventoryBuilder {

    public static func walk(directory: URL) throws -> [String: LocalFileMeta] {
        var out: [String: LocalFileMeta] = [:]
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            // Skip the manifest itself — it's bookkeeping, not a model file.
            if url.lastPathComponent == "mox.json" { continue }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int64) ?? 0
            out[url.lastPathComponent] = LocalFileMeta(sizeBytes: size, sha256: nil)
        }
        return out
    }

    /// Helper for tests + scripts: walk + return the total on-disk bytes
    /// (the same number `mox list` already prints).
    public static func totalBytes(directory: URL) throws -> Int64 {
        let metas = try walk(directory: directory)
        return metas.values.reduce(0) { $0 + $1.sizeBytes }
    }
}