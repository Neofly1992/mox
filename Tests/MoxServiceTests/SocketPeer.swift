import Darwin
import Foundation
import MoxClient
import MoxDomain

/// Blocking socket operations belong on a detached test task, never the main actor.
final class SocketPeer: @unchecked Sendable {
  let fd: Int32
  init(client: ServiceClient, receiveBufferBytes: Int32? = nil) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw MoxError(.connectionLost, "Socket fixture failed") }
    var noPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    if var size = receiveBufferBytes {
      setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port =
      UInt16(URLComponents(string: client.discovery.privateEndpoint)!.port!).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      close(descriptor)
      throw MoxError(.connectionLost, "Socket fixture connect failed")
    }
    fd = descriptor
  }
  deinit { close(fd) }
  func send(_ bytes: Data) throws {
    var offset = 0
    while offset < bytes.count {
      let n = bytes.withUnsafeBytes {
        Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0)
      }
      guard n > 0 else { throw MoxError(.connectionLost, "Socket fixture send failed") }
      offset += n
    }
  }
  func receiveHead() throws -> String {
    var bytes = Data()
    while bytes.count < 16384 {
      var buffer = [UInt8](repeating: 0, count: 1024)
      let n = recv(fd, &buffer, buffer.count, 0)
      guard n > 0 else { throw MoxError(.connectionLost, "Socket fixture response incomplete") }
      bytes.append(contentsOf: buffer.prefix(n))
      if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
        return String(decoding: bytes, as: UTF8.self)
      }
    }
    throw MoxError(.protocolViolation, "Socket fixture response header too large")
  }
  static func generationHead(client: ServiceClient, contentLength: Int) -> Data {
    Data(
      "POST /mox/v1/generations HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(client.discovery.token)\r\nContent-Type: application/json\r\nContent-Length: \(contentLength)\r\n\r\n"
        .utf8)
  }
}
