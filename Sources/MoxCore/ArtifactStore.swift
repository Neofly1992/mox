import Darwin
import Foundation
import OSLog
import MoxDomain

/// File half of the installation transaction. The caller owns the service writer lock,
/// persists the operation before staging, and commits its index only after this returns.
public struct ArtifactStore: Sendable {
  public enum CommitBoundary: Sendable { case manifestWritten, directoryRenamed }
  public let root: URL
  public init(root: URL) throws {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    for directory in [self.root, self.root.appendingPathComponent("staging"), self.root.appendingPathComponent("artifacts"),
      self.root.appendingPathComponent("trash")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard values.isSymbolicLink != true, values.isDirectory == true else {
        throw MoxError(.storageFailed, "Invalid managed artifact directory.")
      }
    }
  }

  public func stagingDirectory(for operationID: UUID) throws -> URL {
    let directory = root.appendingPathComponent("staging/\(operationID.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw MoxError(.storageFailed, "Invalid staging directory.")
    }
    return directory
  }

  public func installedDirectory(for origin: ArtifactOrigin) throws -> URL {
    root.appendingPathComponent("artifacts/\(try ArtifactValidation.identifier(for: origin))")
  }

  /// The staging directory is renamed into place; URLSession may temporarily hold
  /// one additional full file while its validated download is moved into staging.
  public func checkAvailableSpace(for manifest: ArtifactManifest) throws {
    let plan = try spacePlan(for: manifest)
    if let available = plan.availableBytes, available < plan.peakBytes {
      throw MoxError(.resourceLimit, "Insufficient free space for the model and download staging.")
    }
  }

  public func spacePlan(for manifest: ArtifactManifest) throws -> ModelDownloadPlan {
    let values = try root.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    // The "important usage" estimate can be zero for sandboxed temporary
    // volumes even when the filesystem reports usable free blocks.
    let important = values.volumeAvailableCapacityForImportantUsage
    let available = (important ?? 0) > 0
      ? important
      : values.volumeAvailableCapacity.map(Int64.init)
    return try spacePlan(for: manifest, availableBytes: available)
  }

  func checkAvailableSpace(for manifest: ArtifactManifest, availableBytes: Int64?) throws {
    let plan = try spacePlan(for: manifest, availableBytes: availableBytes)
    if let availableBytes, availableBytes < plan.peakBytes {
      throw MoxError(.resourceLimit, "Insufficient free space for the model and download staging.")
    }
  }

  private func spacePlan(for manifest: ArtifactManifest, availableBytes: Int64?) throws -> ModelDownloadPlan {
    let bytes = manifest.files.reduce(Int64(0)) { partial, file in
      let (sum, overflow) = partial.addingReportingOverflow(file.bytes)
      return overflow ? Int64.max : sum
    }
    let largest = manifest.files.map(\.bytes).max() ?? 0
    let (peak, overflow) = bytes.addingReportingOverflow(largest)
    guard !overflow else { throw MoxError(.resourceLimit, "Model size exceeds supported disk capacity.") }
    return ModelDownloadPlan(manifest: manifest, totalBytes: bytes, peakBytes: peak,
      availableBytes: availableBytes)
  }

  /// The injection hook models process death; failures after rename deliberately leave
  /// a recoverable manifest. It does not roll back an already committed snapshot.
  public func commit(
    operationID: UUID, manifest: ArtifactManifest,
    atBoundary: @Sendable (CommitBoundary) throws -> Void = { _ in }
  ) throws -> URL {
    try ArtifactValidation.validate(manifest)
    let staging = try stagingDirectory(for: operationID)
    try verifyContents(manifest, in: staging)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    guard data.count <= ArtifactValidation.maximumManifestBytes else {
      throw MoxError(.resourceLimit, "Installation manifest exceeds its size limit.")
    }
    let manifestURL = staging.appendingPathComponent("mox-manifest.json")
    try data.write(to: manifestURL, options: .atomic)
    try synchronize(manifestURL)
    try synchronize(staging)
    try atBoundary(.manifestWritten)
    let destination = try installedDirectory(for: manifest.origin)
    let result = staging.path.withCString { source in
      destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
    }
    guard result == 0 else {
      if errno == EEXIST { throw MoxError(.busy, "This artifact is already installed.") }
      throw MoxError(.storageFailed, "Atomic artifact installation failed.")
    }
    try synchronize(destination.deletingLastPathComponent())
    try atBoundary(.directoryRenamed)
    return destination
  }

  public func prepareRemoval(_ manifest: ArtifactManifest, id: UUID) throws {
    let source = try installedDirectory(for: manifest.origin)
    let trash = root.appendingPathComponent("trash/\(id.uuidString)")
    if FileManager.default.fileExists(atPath: trash.path) { return }
    // A user may have removed an already-missing managed directory outside Mox.
    // The durable deletion marker can still be completed without a rename.
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    let result = source.path.withCString { from in
      trash.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
    }
    guard result == 0 else { throw MoxError(.storageFailed, "Cannot stage managed artifact removal.") }
    try synchronize(source.deletingLastPathComponent())
    try synchronize(trash.deletingLastPathComponent())
  }
  public func finishRemoval(id: UUID) throws {
    let trash = root.appendingPathComponent("trash/\(id.uuidString)")
    if FileManager.default.fileExists(atPath: trash.path) {
      try FileManager.default.removeItem(at: trash)
    }
  }
  public func removeOrphanTrash(keeping ids: Set<UUID>) throws {
    let trash = root.appendingPathComponent("trash")
    for child in try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: child.lastPathComponent) else {
        throw MoxError(.storageFailed, "Unknown managed trash entry.")
      }
      if !ids.contains(id) { try finishRemoval(id: id) }
    }
  }

  /// Inspect each artifact independently. One damaged installation must not prevent
  /// the service from opening its library and allowing that installation to be removed.
  public func inspectCommitted(_ origin: ArtifactOrigin) throws -> ArtifactManifest {
    try inspectCommittedDirectory(installedDirectory(for: origin))
  }
  func inspectCommittedDirectory(_ child: URL, verifyFiles: Bool = true) throws -> ArtifactManifest {
    try Task.checkCancellation()
    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw MoxError(.storageFailed, "Unexpected managed artifact entry.") }
    let url = child.appendingPathComponent("mox-manifest.json")
    let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
    guard metadata.isSymbolicLink != true, metadata.isRegularFile == true,
      let bytes = metadata.fileSize, bytes <= ArtifactValidation.maximumManifestBytes else { throw MoxError(.storageFailed, "Invalid installed manifest.") }
    let manifest = try JSONDecoder().decode(ArtifactManifest.self, from: Data(contentsOf: url))
    try ArtifactValidation.validate(manifest)
    guard child.lastPathComponent == (try ArtifactValidation.identifier(for: manifest.origin)) else { throw MoxError(.storageFailed, "Artifact identity does not match its directory.") }
    if verifyFiles { try verifyContents(manifest, in: child, synchronizeFiles: false) }
    return manifest
  }

  private func verifyContents(_ manifest: ArtifactManifest, in directory: URL,
    synchronizeFiles: Bool = true) throws {
    let expected = Set(manifest.files.map(\.path))
    guard let entries = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
    else { throw MoxError(.storageFailed, "Cannot enumerate installation files.") }
    for case let url as URL in entries {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
      guard values.isSymbolicLink != true else {
        throw MoxError(.invalidModel, "Installation contains a symbolic link.")
      }
      if values.isDirectory == true { continue }
      let relative = url.standardizedFileURL.pathComponents.dropFirst(
        directory.standardizedFileURL.pathComponents.count).joined(separator: "/")
      guard values.isRegularFile == true,
        expected.contains(relative) || relative == "mox-manifest.json"
      else { throw MoxError(.invalidModel, "Unexpected installation asset.") }
    }
    for file in manifest.files {
      try Task.checkCancellation()
      try ArtifactValidation.verify(file, in: directory)
      if synchronizeFiles { try synchronize(directory.appendingPathComponent(file.path)) }
    }
    // Installation and local import share the same format and resource validation.
    let modelRoot = manifest.origin.variant.isEmpty
      ? directory : directory.appendingPathComponent(manifest.origin.variant)
    _ = try LocalModel(path: modelRoot.path)
  }

  private func synchronize(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw MoxError(.storageFailed, "Cannot open installation for synchronization.") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw MoxError(.storageFailed, "Cannot synchronize installation data.")
    }
  }
}
