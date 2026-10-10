import Foundation

public enum DoctorStatus: String, Codable, Sendable {
  case passed, warning, failed, skipped, timedOut, cancelled
}
public struct DoctorResult: Codable, Sendable {
  public let id: String
  public let status: DoctorStatus
  public let reason: String
  public let suggestion: String
  public init(id: String, status: DoctorStatus, reason: String, suggestion: String = "") {
    self.id = id
    self.status = status
    self.reason = reason
    self.suggestion = suggestion
  }
}
public struct DoctorReport: Codable, Sendable {
  public let productVersion: String
  public let buildID: String
  public let results: [DoctorResult]
  public let events: [DiagnosticEvent]
  public init(results: [DoctorResult], events: [DiagnosticEvent] = []) {
    productVersion = Wire.productVersion
    buildID = Wire.buildID
    self.results = results
    self.events = events
  }
  /// 0: completed without failures (warnings/skips allowed); 1: check failure/timeout;
  /// 130: cancelled. CLI argument errors use the existing exit code 2.
  public var exitCode: Int32 {
    if results.contains(where: { $0.status == .cancelled }) { return 130 }
    return results.contains(where: { $0.status == .failed || $0.status == .timedOut }) ? 1 : 0
  }
}

/// Exactly one explicit expensive check. UUID permits cancellation even after HTTP disconnect.
public struct DoctorInspectionBody: Codable, Sendable {
  public let requestID: UUID
  public let model: GenerateBody.Model?
  public let source: PullBody?
  public init(requestID: UUID = UUID(), model: GenerateBody.Model? = nil, source: PullBody? = nil) {
    self.requestID = requestID
    self.model = model
    self.source = source
  }
}
