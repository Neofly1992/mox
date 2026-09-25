import Foundation

public struct DiagnosticEvent: Codable, Sendable {
  public var date: Date = .now
  public let stage: String
  public let code: String
  public let instanceID: UUID?
  public let requestID: UUID?
  public init(stage: String, code: String, instanceID: UUID? = nil, requestID: UUID? = nil) {
    self.stage = String(stage.prefix(64))
    self.code = String(code.prefix(128))
    self.instanceID = instanceID
    self.requestID = requestID
  }
}
/// Events contain only producer-owned classifications/IDs; never upstream free-form text.
public struct DiagnosticRing: Sendable {
  public private(set) var events: [DiagnosticEvent] = []
  private static let eventLimit = 256
  private static let byteLimit = 256 * 1024
  private static let singleEventLimit = 4 * 1024
  private var bytes = 0
  public init() {}
  public mutating func record(_ event: DiagnosticEvent) {
    let size = (try? Wire.encode(event).count) ?? 0
    guard size <= Self.singleEventLimit else { return }
    events.append(event)
    bytes += size
    while events.count > Self.eventLimit || bytes > Self.byteLimit {
      bytes -= (try? Wire.encode(events.removeFirst()).count) ?? 0
    }
  }
}
