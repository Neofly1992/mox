import Foundation
import MoxCore
import MoxDomain
import MoxPersistence

extension DownloadManager {
  func snapshot() async throws -> ModelLibrarySnapshot {
    var result = ModelLibrarySnapshot()
    result.configuration = try await configuration()
    var offset = 0
    while true {
      let page = try await installations(offset: offset)
      result.installations += page
      if page.count < 100 { break }
      offset += page.count
    }
    offset = 0
    while true {
      let page = try await operations(offset: offset)
      result.operations += page
      if page.count < 100 { break }
      offset += page.count
    }
    return result
  }
}

extension RuntimeStore {
  func readLibrary() async throws -> ModelLibrarySnapshot {
    var result = ModelLibrarySnapshot()
    result.configuration = try configuration()
    var offset = 0
    while true {
      let page = try installations(offset: offset, limit: 100)
      result.installations += page
      if page.count < 100 { break }
      offset += page.count
    }
    offset = 0
    while true {
      let page = try operations(offset: offset, limit: 100)
      result.operations += page
      if page.count < 100 { break }
      offset += page.count
    }
    return result
  }
  func saveLibrary(_ snapshot: ModelLibrarySnapshot) throws {
    try commit(
      .init(
        configuration: snapshot.configuration, installations: snapshot.installations,
        operations: snapshot.operations))
  }
}
