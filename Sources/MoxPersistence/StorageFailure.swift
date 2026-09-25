import Foundation
import MoxDomain
import OSLog

/// Only operation names and allowlisted NSError metadata cross the storage boundary.
public struct StorageFailure: Error, Codable, Sendable, Equatable {
  public enum Stage: String, Codable, Sendable { case open, recover, fetch, save }
  public let stage: Stage
  public let domain: String
  public let systemCode: Int?
  public let code: MoxError.Code
  public var userError: MoxError {
    MoxError(code, "聊天存储操作失败（\(stage.rawValue)）。已有数据保留，可导出诊断。")
  }
  public static func capture(_ error: Error, stage: Stage) -> StorageFailure {
    if let failure = error as? StorageFailure { return failure }
    let ns = error as NSError
    let allowed = [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(ns.domain)
    let failure = StorageFailure(
      stage: stage, domain: allowed ? ns.domain : "redacted",
      systemCode: allowed ? ns.code : nil, code: (error as? MoxError)?.code ?? .storageFailed)
    Logger(subsystem: "dev.mox", category: "storage").error(
      "stage=\(failure.stage.rawValue, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.systemCode.map(String.init) ?? "redacted", privacy: .public) error=\(failure.code.rawValue, privacy: .public)"
    )
    return failure
  }
}
