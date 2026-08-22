import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// Network-less tests for the chunked-download invariants. We never hit a
/// real HTTP server — `MockHttpProtocol` serves a fixed in-memory payload,
/// the Downloader consumes it via a mock URLSession, and we assert the
/// file on disk is byte-identical and that progress reaches 1.0. The
/// original byte-at-a-time regression made every multi-GB pull
/// effectively unrunnable; these tests pin the chunked write path so it
/// cannot return silently.
@Suite("Downloader chunking")
struct DownloaderTests {

    private func makeTmpDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("URLSessionDownloader writes all bytes and reports 1.0 progress")
    func streamingDownloaderRoundtrip() async throws {
        // 3 MiB so the 1 MiB chunk threshold fires at least once, exercising
        // the partial-buffer flush path that was the original bug.
        let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 & 0xFF) })
        let url = URL(string: "http://mox.test/file.bin")!
        MockHttpProtocol.register(url: url, payload: payload, contentLength: Int64(payload.count), acceptRanges: false)
        defer { MockHttpProtocol.unregister(url) }

        let tmpDir = try makeTmpDir("download")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dest = tmpDir.appendingPathComponent("out.bin")

        let progressCalls = LockedProgress()
        let downloader = URLSessionDownloader(session: MockHttpProtocol.makeSession())
        try await downloader.download(from: url, to: dest) { p in
            progressCalls.append(p)
        }

        let written = try Data(contentsOf: dest)
        #expect(written == payload)
        #expect(progressCalls.last() == 1.0)
        #expect(progressCalls.contains { $0 > 0 && $0 < 1 })
    }

    @Test("ResumableDownloader small-file fallback produces identical bytes")
    func resumableFallbackPath() async throws {
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })  // 4 KiB, < 50 MiB threshold
        let url = URL(string: "http://mox.test/file.bin")!
        MockHttpProtocol.register(url: url, payload: payload, contentLength: Int64(payload.count), acceptRanges: false)
        defer { MockHttpProtocol.unregister(url) }

        let tmpDir = try makeTmpDir("resume-fallback")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dest = tmpDir.appendingPathComponent("out.bin")

        let downloader = ResumableDownloader(session: MockHttpProtocol.makeSession())
        try await downloader.download(from: url, to: dest, progress: nil)

        let written = try Data(contentsOf: dest)
        #expect(written == payload)
    }

    @Test("ResumableDownloader range path assembles correctly")
    func resumableRangePath() async throws {
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 & 0xFF) })  // 2 MiB, > 50 MiB threshold? no — too small
        // Bump to 60 MiB so the parallel Range path actually runs. We keep
        // it modest to keep test runtime sane.
        let payloadBig = Data((0..<(60 * 1024 * 1024)).map { UInt8($0 & 0xFF) })
        let url = URL(string: "http://mox.test/file.bin")!
        MockHttpProtocol.register(url: url, payload: payloadBig, contentLength: Int64(payloadBig.count), acceptRanges: true)
        defer { MockHttpProtocol.unregister(url) }

        let tmpDir = try makeTmpDir("resume-range")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dest = tmpDir.appendingPathComponent("out.bin")

        let downloader = ResumableDownloader(session: MockHttpProtocol.makeSession())
        try await downloader.download(from: url, to: dest, progress: { _ in })

        let written = try Data(contentsOf: dest)
        #expect(written == payloadBig)
    }
}

/// Concurrency-safe progress collector. The downloader callbacks run from
/// arbitrary URLSession threads, so the array must be guarded by a lock.
final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(v)
    }
    func last() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return values.last
    }
    func contains(_ predicate: (Double) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains(where: predicate)
    }
}

/// A `URLProtocol` subclass that serves a fixed in-memory payload without
/// making any real network calls. Used by the downloader chunking tests
/// so the chunked-write invariants can be asserted without spinning up a
/// real socket.
final class MockHttpProtocol: URLProtocol {

    struct Registration: Sendable {
        let payload: Data
        let contentLength: Int64
        let acceptRanges: Bool
    }

    nonisolated(unsafe) private static var registry: [URL: Registration] = [:]
    private static let lock = NSLock()

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHttpProtocol.self] + (config.protocolClasses ?? [])
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }

    static func register(url: URL, payload: Data, contentLength: Int64, acceptRanges: Bool) {
        lock.lock(); defer { lock.unlock() }
        registry[url] = Registration(payload: payload, contentLength: contentLength, acceptRanges: acceptRanges)
    }

    static func unregister(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        registry.removeValue(forKey: url)
    }

    private static func registration(for url: URL) -> Registration? {
        lock.lock(); defer { lock.unlock() }
        return registry[url]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        registration(for: request.url!) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let reg = Self.registration(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let isHead = (request.httpMethod?.uppercased() ?? "GET") == "HEAD"
        var headers = [
            "Content-Length": "\(reg.contentLength)",
            "Accept-Ranges": reg.acceptRanges ? "bytes" : "none",
        ]
        var status = 200
        var body = reg.payload

        if !isHead, reg.acceptRanges, let rangeHeader = request.value(forHTTPHeaderField: "Range") {
            let stripped = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts = stripped.split(separator: "-")
            if parts.count == 2,
               let start = Int64(parts[0]),
               let end = Int64(parts[1]),
               start >= 0, end >= start, end < reg.contentLength {
                let len = Int(end - start + 1)
                body = reg.payload.subdata(in: Int(start)..<(Int(start) + len))
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(reg.contentLength)"
                headers["Content-Length"] = "\(body.count)"
            }
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        if !isHead {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
