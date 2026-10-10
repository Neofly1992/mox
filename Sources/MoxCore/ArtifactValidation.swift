import CryptoKit
import Foundation
import MoxDomain

/// Shared by source plans, installation, and recovery; validation never follows a symlink.
public enum ArtifactValidation {
  public static let maximumFiles = 10_000
  public static let maximumManifestBytes = 8 * 1024 * 1024
  private static let hashChunkBytes = 1024 * 1024

  public static func relativePath(_ path: String) throws {
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 4096,
      !path.contains("\\"), !path.contains(":"),
      path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      path != "mox-manifest.json"
    else { throw MoxError(.invalidModel, "Invalid artifact relative path.") }
  }

  public static func validate(_ manifest: ArtifactManifest) throws {
    guard manifest.schemaVersion == 1, !manifest.files.isEmpty,
      manifest.files.count <= maximumFiles,
      manifest.origin.repository.split(separator: "/", omittingEmptySubsequences: false).count == 2,
      isHex(manifest.origin.revision, count: 40)
    else { throw MoxError(.invalidModel, "Invalid artifact identity or manifest version.") }
    try relativePath(manifest.origin.repository)
    if !manifest.origin.variant.isEmpty { try relativePath(manifest.origin.variant) }
    var paths = Set<String>()
    var total: Int64 = 0
    for file in manifest.files {
      try relativePath(file.path)
      let canonical = file.path.precomposedStringWithCanonicalMapping.lowercased()
      guard paths.insert(canonical).inserted, file.bytes >= 0,
        !total.addingReportingOverflow(file.bytes).overflow
      else { throw MoxError(.invalidModel, "Duplicate path or invalid artifact size.") }
      total += file.bytes
      switch file.digest {
      case .sha256(let value):
        guard isHex(value, count: 64) else {
          throw MoxError(.invalidModel, "Invalid SHA256 evidence.")
        }
      case .gitBlobSHA1(let value):
        guard isHex(value, count: 40) else {
          throw MoxError(.invalidModel, "Invalid Git blob evidence.")
        }
      }
    }
    // A file cannot also be a directory containing another file.
    for path in paths {
      let components = path.split(separator: "/")
      for count in 1..<components.count {
        guard !paths.contains(components.prefix(count).joined(separator: "/")) else {
          throw MoxError(.invalidModel, "Conflicting artifact file paths.")
        }
      }
    }
  }

  public static func identifier(for origin: ArtifactOrigin) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(origin)).map { String(format: "%02x", $0) }.joined()
  }

  public static func verify(_ file: ArtifactFile, in root: URL) throws {
    try relativePath(file.path)
    var url = root
    for component in file.path.split(separator: "/") {
      url.appendPathComponent(String(component))
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw MoxError(.invalidModel, "Artifact contains a symbolic link.")
      }
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, Int64(values.fileSize ?? -1) == file.bytes else {
      throw MoxError(.invalidModel, "Artifact file size or type does not match its manifest.")
    }
    let asset = try ModelAssetFile(url)
    guard Int64(asset.size) == file.bytes else {
      throw MoxError(.invalidModel, "Artifact changed during verification.")
    }
    var sha256 = SHA256()
    var git = Insecure.SHA1()
    git.update(data: Data("blob \(file.bytes)\0".utf8))
    var count: Int64 = 0
    while count < file.bytes {
      let chunk = try asset.read(count: min(hashChunkBytes, Int(file.bytes - count)))
      try Task.checkCancellation()
      count += Int64(chunk.count)
      guard count <= file.bytes else {
        throw MoxError(.invalidModel, "Artifact file changed during verification.")
      }
      switch file.digest {
      case .sha256: sha256.update(data: chunk)
      case .gitBlobSHA1: git.update(data: chunk)
      }
    }
    let actual: String
    let expected: String
    switch file.digest {
    case .sha256(let value):
      actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
      expected = value
    case .gitBlobSHA1(let value):
      actual = git.finalize().map { String(format: "%02x", $0) }.joined()
      expected = value
    }
    guard count == file.bytes, actual == expected.lowercased() else {
      throw MoxError(.invalidModel, "Artifact digest verification failed; download this file again.")
    }
  }

  private static func isHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}
