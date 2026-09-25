import CryptoKit
import Foundation

/// Stable runtime identifier for a canonical local directory; this is not a content revision.
public enum LocalModelIdentity {
  private static let digestBytes = 8
  public static func identifier(for directory: URL) -> String {
    let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
    return SHA256.hash(data: Data(canonical.path.utf8)).prefix(digestBytes).map {
      String(format: "%02x", $0)
    }.joined()
  }
}
