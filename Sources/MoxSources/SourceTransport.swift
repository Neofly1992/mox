import Foundation
import MoxDomain
import MoxCore

/// Credentials are attached only to an explicitly selected access origin. Redirects
/// never inherit credentials across origins, including changes to port or scheme.
final class SourceRedirectPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let limitBytes: Int64?
  private let lock = NSLock()
  private var exceeded = false
  init(limitBytes: Int64? = nil) { self.limitBytes = limitBytes }
  var didExceedLimit: Bool { lock.withLock { exceeded } }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL) {}
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if let limitBytes, totalBytesWritten > limitBytes {
      lock.withLock { exceeded = true }
      downloadTask.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let target = request.url, target.scheme == "https", target.user == nil,
      target.password == nil else { completionHandler(nil); return }
    var safe = request
    if !Self.sameOrigin(task.originalRequest?.url, target) {
      safe.setValue(nil, forHTTPHeaderField: "Authorization")
      safe.setValue(nil, forHTTPHeaderField: "Cookie")
    }
    completionHandler(safe)
  }
  static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && (lhs.port ?? 443) == (rhs.port ?? 443)
  }
}

struct SourceTransport: Sendable {
  let endpoint: URL
  let token: String?
  let session: URLSession
  init(endpoint: URL, token: String? = nil) throws {
    guard endpoint.scheme == "https", endpoint.host != nil,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
      endpoint.fragment == nil,
      endpoint.path.isEmpty || endpoint.path == "/" else { throw MoxError(.invalidParameters, "Source endpoint must be an HTTPS origin.") }
    self.endpoint = endpoint
    self.token = token
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 3600
    self.session = URLSession(configuration: config, delegate: SourceRedirectPolicy(), delegateQueue: nil)
  }
  func request(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
    var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw MoxError(.invalidParameters, "Invalid source request.") }
    var request = URLRequest(url: url)
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }
  func json(path: String, query: [URLQueryItem] = []) async throws -> Data {
    let (bytes, response) = try await session.bytes(for: request(path: path, query: query))
    try validate(response)
    var data = Data()
    for try await byte in bytes {
      guard data.count < 8 * 1024 * 1024 else { throw MoxError(.resourceLimit, "Source metadata exceeds 8 MiB.") }
      data.append(byte)
    }
    return data
  }
  func download(_ file: ArtifactFile, request: URLRequest, to root: URL) async throws {
    try ArtifactValidation.relativePath(file.path)
    let delegate = SourceRedirectPolicy(limitBytes: file.bytes)
    let temporary: URL
    let response: URLResponse
    do { (temporary, response) = try await session.download(for: request, delegate: delegate) }
    catch {
      if delegate.didExceedLimit {
        throw MoxError(.resourceLimit, "Source file exceeds its declared size.")
      }
      throw error
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    try validate(response)
    let destination = root.appendingPathComponent(file.path)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: temporary, to: destination)
    do { try ArtifactValidation.verify(file, in: root) } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }
  func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw MoxError(.invalidModel, "Source request failed (HTTP \(code)); check access and revision.")
    }
  }
}
