import Darwin
import Foundation
import MoxDomain
import Testing
@testable import MoxCore

@Test func modelAssetReaderRejectsSpecialFilesAndDetectsChanges() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let pipe = root.appendingPathComponent("pipe")
  #expect(mkfifo(pipe.path, 0o600) == 0)
  #expect(throws: MoxError.self) { _ = try ModelAssetFile(pipe) }
  #expect(throws: MoxError.self) { _ = try ModelAssetFile(root) }
  #expect(throws: MoxError.self) { _ = try ModelAssetFile(URL(fileURLWithPath: "/dev/zero")) }
  let regular = root.appendingPathComponent("regular")
  try Data([1, 2, 3]).write(to: regular)
  let asset = try ModelAssetFile(regular)
  #expect(try asset.read(count: 1) == Data([1]))
  let writer = try FileHandle(forWritingTo: regular)
  try writer.truncate(atOffset: 1)
  try writer.close()
  #expect(throws: MoxError.self) { _ = try asset.read(count: 2) }
}

@Test func localReferenceSymlinkMustResolveToRegularAsset() throws {
  let model = try fixture()
  defer { try? FileManager.default.removeItem(at: model.directory) }
  let source = model.directory.appendingPathComponent("model.safetensors")
  let target = model.directory.appendingPathComponent("weight-data")
  try FileManager.default.moveItem(at: source, to: target)
  try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
  let linked = try LocalModel(path: model.directory.path)
  #expect(linked.weightBytes == model.weightBytes)
  try FileManager.default.removeItem(at: target)
  #expect(mkfifo(target.path, 0o600) == 0)
  #expect(throws: MoxError.self) { _ = try LocalModel(path: model.directory.path) }
}
