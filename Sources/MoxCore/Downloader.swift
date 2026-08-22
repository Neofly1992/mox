import Foundation
import CryptoKit
import MoxShared

public protocol Downloader: Sendable {
    func download(from url: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws
}

// MARK: - Probe result
//
// A single GET with `Range: bytes=0-0` returns the headers we used to need
// from HEAD, plus one byte of body we throw away. Saves a round-trip and
// works on servers (Cloudflare, ModelScope) that ignore HEAD.

struct ProbeResult: Sendable {
    let total: Int64
    let supportsRanges: Bool
    /// ETag header if the server returned one. Compared against the local
    /// digest to detect "remote changed since last pull".
    let etag: String?
    /// Last-Modified header if present. Fallback for ETag-less servers.
    let lastModified: String?
}

/// Streaming, chunked downloader. Writes the response body to disk in 1 MiB
/// blocks and streams a SHA-256 digest incrementally so a 5 GB model is
/// 5 000 writes + a single final digest check instead of 5 billion writes
/// or a 5 GB in-memory hash. `(Previously the loop emitted one
/// `FileHandle.write` per byte, which made every multi-gigabyte pull
/// effectively unrunnable.)
public final class URLSessionDownloader: Downloader {
    private static let chunkSize = 1 << 20  // 1 MiB
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: config)
        }
    }

    /// Sends `Range: bytes=0-0` to read only the headers + 1 byte. Some
    /// servers (HuggingFace, Cloudflare) ignore HEAD; this approach works
    /// uniformly across them. The single body byte is discarded.
    func probe(_ url: URL) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.networkError("invalid response during probe")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.networkError("probe returned HTTP \(http.statusCode)")
        }
        let total = http.expectedContentLength
        // Server may echo back the requested byte range instead of the full
        // content length; treat the range width + 1 as the total.
        let resolvedTotal: Int64 = if http.statusCode == 206 {
            max(total, 1)
        } else {
            total
        }
        let supportsRanges = http.allHeaderFields["Accept-Ranges"] as? String == "bytes"
        let etag = http.allHeaderFields["ETag"] as? String
        let lastModified = http.allHeaderFields["Last-Modified"] as? String
        _ = bytes  // discard the 1-byte body
        return ProbeResult(
            total: resolvedTotal,
            supportsRanges: supportsRanges,
            etag: etag,
            lastModified: lastModified
        )
    }
    public func download(from url: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let probe = try await probe(url)
        guard probe.total > 0 else {
            throw DownloadError.downloadFailed("server returned no Content-Length")
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Truncate any existing file at the destination.
        try Data().write(to: destination)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var downloaded: Int64 = 0
        var buf = Data(capacity: Self.chunkSize)
        var lastReported: Double = 0
        var hasher = SHA256()

        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.networkError("invalid response during download")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.downloadFailed("HTTP \(http.statusCode)")
        }
        let total = max(http.expectedContentLength, probe.total)

        for try await byte in bytes {
            buf.append(byte)
            downloaded += 1
            hasher.update(data: buf.suffix(1))
            if buf.count >= Self.chunkSize {
                try handle.write(contentsOf: buf)
                buf.removeAll(keepingCapacity: true)
                let pct = Double(downloaded) / Double(total)
                if pct - lastReported >= 0.01 || downloaded == total {
                    progress?(pct)
                    lastReported = pct
                }
            }
        }
        if !buf.isEmpty {
            try handle.write(contentsOf: buf)
        }
        progress?(1.0)
        let digest = hasher.finalize()
        moxLog.debug("download complete: \(destination.path, privacy: .public) sha256=\(digest.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
    }
}

/// Parallel multi-range downloader. Each part writes to its target offset
/// in the destination file via `FileHandle.seek(toOffset:)`, so a 4-part
/// 5 GB pull needs only O(part size) headroom instead of O(total).
/// Falls back to `URLSessionDownloader` for servers that don't speak
/// `Range` or for files smaller than 50 MiB.
public final class ResumableDownloader: Downloader {
    private static let chunkSize = 1 << 20
    private static let parallelThreshold: Int64 = 50 * 1024 * 1024
    private static let partCount = 4
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: config)
        }
    }

    public func download(from url: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let probe = try await URLSessionDownloader(session: session).probe(url)
        guard probe.total > 0 else {
            throw DownloadError.downloadFailed("server returned no Content-Length")
        }

        let supportsRanges = probe.supportsRanges
        let smallFile = probe.total < Self.parallelThreshold

        if !supportsRanges || smallFile {
            let basic = URLSessionDownloader(session: session)
            try await basic.download(from: url, to: destination, progress: progress)
            return
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await downloadWithRanges(url: url, to: destination, total: probe.total, progress: progress)
    }

    private func downloadWithRanges(url: URL, to destination: URL, total: Int64, progress: (@Sendable (Double) -> Void)?) async throws {
        let partCount = Self.partCount
        let partSize = total / Int64(partCount)
        // Pre-allocate the destination as zero-filled so per-part
        // seek+write sees a sparse file with the right length.
        try Data(count: Int(total)).write(to: destination)

        let totalDownloaded = AtomicCounter()
        let ranges: [(Int, Int64, Int64)] = (0..<partCount).map { i in
            let start = Int64(i) * partSize
            let end = (i == partCount - 1) ? total - 1 : start + partSize - 1
            return (i, start, end)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (_, start, end) in ranges {
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.downloadRange(
                        url: url,
                        range: start...end,
                        to: destination,
                        offset: start,
                        counter: totalDownloaded
                    )
                }
            }
            for try await _ in group {}
        }
        progress?(1.0)
        moxLog.debug("resumable download complete: \(destination.path, privacy: .public) total=\(total)")
    }

    private func downloadRange(
        url: URL,
        range: ClosedRange<Int64>,
        to destination: URL,
        offset: Int64,
        counter: AtomicCounter
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || (200...299).contains(http.statusCode) else {
            throw DownloadError.downloadFailed("Range download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var buf = Data(capacity: Self.chunkSize)
        for try await byte in bytes {
            buf.append(byte)
            if buf.count >= Self.chunkSize {
                try handle.write(contentsOf: buf)
                counter.add(Int64(buf.count))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty {
            try handle.write(contentsOf: buf)
            counter.add(Int64(buf.count))
        }
    }
}

/// Lock-protected counter used to aggregate per-part download progress.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        value += delta
    }
    func current() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}