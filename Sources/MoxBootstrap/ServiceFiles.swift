import CryptoKit
import Darwin
import Foundation
import MoxDomain
import MoxProtocol
import Security

/// Kernel lock is the authority; the persistent inode is never unlinked.
public final class DirectoryLock: @unchecked Sendable {
  private let fd: Int32
  public init(directory: URL, name: String) throws {
    let descriptor = open(
      directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw MoxError(.serviceConflict, "Cannot open ownership lock.") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0
    else {
      close(descriptor)
      throw MoxError(
        .serviceConflict, "This data directory already has an owner or unsafe lock permissions.")
    }
    // Transfer ownership only after validation; a throwing initializer must close once.
    fd = descriptor
  }
  deinit {
    flock(fd, LOCK_UN)
    close(fd)
  }
}
public struct ServiceFiles: Sendable {
  public let root: URL
  public let run: URL
  public var rootIdentity: String {
    SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static var defaultRoot: String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Mox"
    ).path
  }
  public init(path: String, prepareDirectories: Bool = true) throws {
    let requested = URL(fileURLWithPath: path).standardizedFileURL
    if prepareDirectories {
      try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
    }
    root = requested.resolvingSymlinksInPath()
    run = root.appendingPathComponent("run", isDirectory: true)
    if prepareDirectories { try Self.secureDirectory(run) }
  }
  public static func secureDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o077 == 0
    else {
      throw MoxError(.serviceConflict, "Data directory ownership or permissions are unsafe.")
    }
  }
  public func lock() throws -> DirectoryLock {
    try DirectoryLock(directory: run, name: "service.lock")
  }
  public func read(matchingBuild: Bool = true) throws -> Discovery? {
    let path = run.appendingPathComponent("discovery.json").path
    try Task.checkCancellation()
    var before = stat()
    if lstat(path, &before) < 0 {
      if errno == ENOENT { return nil }
      throw MoxError(.serviceConflict, "Cannot inspect service discovery.")
    }
    guard before.st_mode & S_IFMT == S_IFREG else {
      throw MoxError(.serviceConflict, "Unsafe discovery file type.")
    }
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw MoxError(.serviceConflict, "Cannot read service discovery.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= 16384,
      info.st_dev == before.st_dev, info.st_ino == before.st_ino
    else { throw MoxError(.serviceConflict, "Unsafe discovery file.") }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    var count = 0
    while count < bytes.count {
      try Task.checkCancellation()
      let remaining = bytes.count - count
      let n = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress!.advanced(by: count), remaining)
      }
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { throw MoxError(.serviceConflict, "Incomplete discovery file.") }
      count += n
    }
    let d: Discovery
    do { d = try Wire.decode(Discovery.self, Data(bytes)) } catch {
      throw MoxError(.serviceConflict, "Malformed discovery file.")
    }
    guard d.schema == 1, d.identity.uid == getuid(), d.identity.rootIdentity == rootIdentity else {
      throw MoxError(
        .incompatibleService, "Existing service version or data directory does not match.")
    }
    if matchingBuild,
      d.identity.buildID != Wire.buildID || d.identity.protocolVersion != Wire.version
    {
      throw MoxError(.incompatibleService, "Existing service version does not match.")
    }
    guard let u = URLComponents(string: d.privateEndpoint), u.scheme == "http",
      u.host == "127.0.0.1",
      let port = u.port, (1...65535).contains(port), u.user == nil, u.password == nil,
      u.query == nil, u.fragment == nil, u.path.isEmpty, d.token.utf8.count == 64
    else {
      throw MoxError(.protocolViolation, "Invalid service endpoint.")
    }
    return d
  }
  public func publish(_ discovery: Discovery) throws {
    let temporary = run.appendingPathComponent(".ready-\(UUID().uuidString)")
    let data = try Wire.encode(discovery)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MoxError(.serviceConflict, "Cannot publish service readiness.") }
    defer {
      close(fd)
      try? FileManager.default.removeItem(at: temporary)
    }
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard written == data.count, fsync(fd) == 0,
      rename(temporary.path, run.appendingPathComponent("discovery.json").path) == 0
    else {
      throw MoxError(.serviceConflict, "Cannot commit service readiness.")
    }
  }
  public func remove(instanceID: UUID) {
    if let current = try? read(), current.identity.instanceID == instanceID {
      try? FileManager.default.removeItem(at: run.appendingPathComponent("discovery.json"))
    }
  }
  public static func token() throws -> String {
    var data = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, data.count, &data) == errSecSuccess else {
      throw MoxError(.serviceConflict, "Cannot create service credential.")
    }
    return data.map { String(format: "%02x", $0) }.joined()
  }
}
