import Foundation
import Hummingbird
import HummingbirdCore
import MoxDomain
import MoxProtocol
import NIOCore

/// A single connection policy for both listeners. Callers close the channel after
/// writing an error if reading stops before the request body is exhausted.
enum RequestBodyReader {
  static let deadline: Duration = .seconds(15)
  static let idleTimeoutSeconds: Int64 = 15

  static func read(_ request: Request, channel: any Channel, limit: Int,
    description: String) async throws -> Data {
    if let length = request.headers[.contentLength].flatMap(Int.init), length > limit {
      throw MoxError(.bodyTooLarge, description)
    }
    let timeout = Task {
      do { try await Task.sleep(for: deadline) } catch { return }
      channel.close(mode: .all, promise: nil)
    }
    defer { timeout.cancel() }
    var data = Data()
    for try await buffer in request.body {
      guard buffer.readableBytes <= limit - data.count else {
        throw MoxError(.bodyTooLarge, description)
      }
      data.append(contentsOf: buffer.readableBytesView)
    }
    return data
  }

  static func rejectedBody(_ bytes: Data, closing channel: any Channel) -> ResponseBody {
    ResponseBody { writer in
      let deadline = Task {
        do { try await Task.sleep(for: ServiceTiming.writeDeadline) } catch { return }
        channel.close(mode: .all, promise: nil)
      }
      defer {
        deadline.cancel()
        channel.close(mode: .all, promise: nil)
      }
      try await writer.write(ByteBuffer(bytes: bytes))
      try await writer.finish(nil)
    }
  }
}
