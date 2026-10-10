import Darwin
import Foundation
import MoxDomain

/// A model asset must be a regular file before opening and on the opened descriptor.
/// Nonblocking open also closes the FIFO replacement race. Reads are bounded and
/// cooperatively cancellable; this cannot interrupt a stalled filesystem kernel call.
final class ModelAssetFile {
  private let descriptor: Int32
  let size: Int
  private var position = 0
  private static let readChunkBytes = 1024 * 1024

  init(_ url: URL, maximumBytes: Int = Int.max) throws {
    try Task.checkCancellation()
    var before = stat()
    guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
      throw MoxError(.invalidModel, "Model asset is not a regular file.")
    }
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MoxError(.invalidModel, "Cannot open model asset.") }
    var opened = stat()
    guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
      opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
      opened.st_size >= 0, opened.st_size <= maximumBytes
    else {
      close(fd)
      throw MoxError(.invalidModel, "Model asset type, identity or size is invalid.")
    }
    descriptor = fd
    size = Int(opened.st_size)
  }
  deinit { close(descriptor) }

  func validateSize() throws {
    var current = stat()
    guard fstat(descriptor, &current) == 0, current.st_size == size else {
      throw MoxError(.invalidModel, "Model asset changed during inspection.")
    }
  }
  func read(count: Int) throws -> Data {
    guard count >= 0, count <= size - position else {
      throw MoxError(.invalidModel, "Model asset read exceeds its size.")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(count, Self.readChunkBytes))
    while result.count < count {
      try Task.checkCancellation()
      let wanted = min(buffer.count, count - result.count)
      let bytes = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
      if bytes < 0, errno == EINTR { continue }
      guard bytes > 0 else { throw MoxError(.invalidModel, "Model asset is incomplete or unreadable.") }
      result.append(contentsOf: buffer.prefix(bytes))
    }
    position += result.count
    try validateSize()
    try Task.checkCancellation()
    return result
  }
}
