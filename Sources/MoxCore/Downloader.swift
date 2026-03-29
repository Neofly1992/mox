import Foundation
import MoxShared

public protocol Downloader: Sendable {
    func download(from url: URL, to destination: URL, progress: ((Double) -> Void)?) async throws
}

public enum DownloaderError: Error, LocalizedError {
    case invalidURL
    case networkError(String)
    case httpError(Int)
    case noContentLength
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let msg): return "Network error: \(msg)"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noContentLength: return "Cannot determine content length"
        }
    }
}

public final class URLSessionDownloader: Downloader {
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }
    
    public func download(from url: URL, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        
        guard let http = response as? HTTPURLResponse else {
            throw DownloaderError.networkError("Invalid response")
        }
        
        guard (200...299).contains(http.statusCode) else {
            throw DownloaderError.httpError(http.statusCode)
        }
        
        let total = http.expectedContentLength
        guard total > 0 else {
            throw DownloaderError.noContentLength
        }
        
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: destination)
        
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        
        var downloaded: Int64 = 0
        
        for try await byte in bytes {
            try handle.write(contentsOf: Data([byte]))
            downloaded += 1
            progress?(Double(downloaded) / Double(total))
        }
    }
}

public final class ResumableDownloader: Downloader {
    private let session: URLSession
    private let tempDir: URL
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mox")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    public func download(from url: URL, to destination: URL, progress: ((Double) -> Void)?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let (_, headResponse) = try await session.data(for: request)
        guard let head = headResponse as? HTTPURLResponse else { throw DownloaderError.networkError("Invalid response") }
        
        let total = head.expectedContentLength
        guard total > 0 else { throw DownloaderError.noContentLength }
        
        let supportsRanges = head.allHeaderFields["Accept-Ranges"] as? String == "bytes"
        let smallFile = total < 50 * 1024 * 1024
        
        if !supportsRanges || smallFile {
            let basic = URLSessionDownloader()
            try await basic.download(from: url, to: destination, progress: progress)
            return
        }
        
        try await downloadWithRanges(url: url, to: destination, total: total, progress: progress)
    }
    
    private func downloadWithRanges(url: URL, to destination: URL, total: Int64, progress: ((Double) -> Void)?) async throws {
        let partCount = 4
        let partSize = total / Int64(partCount)
        let tempFiles = (0..<partCount).map { tempDir.appendingPathComponent("part\($0)") }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<partCount {
                let start = Int64(i) * partSize
                let end = i == partCount - 1 ? total - 1 : start + partSize - 1
                
                group.addTask {
                    try await self.downloadRange(url: url, range: start...end, to: tempFiles[i])
                }
            }
            
            for try await _ in group {}
        }
        
        var combined = Data()
        for url in tempFiles {
            let data = try Data(contentsOf: url)
            combined.append(data)
            try FileManager.default.removeItem(at: url)
        }
        try combined.write(to: destination)
        
        progress?(1.0)
    }
    
    private func downloadRange(url: URL, range: ClosedRange<Int64>, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || (200...299).contains(http.statusCode) else {
            throw DownloaderError.networkError("Range download failed")
        }
        
        try data.write(to: destination)
    }
}
