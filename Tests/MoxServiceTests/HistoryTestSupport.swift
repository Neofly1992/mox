import MoxPersistence
import Testing

extension ConversationStore {
  /// Small fixtures only. Large-history tests must exercise pages explicitly.
  func testSnapshots() async throws -> [ConversationSnapshot] {
    let page = try list()
    #expect(!page.hasMore)
    return try page.items.map { summary in
      let value = try detail(summary.id)
      #expect(!value.hasMore)
      return value
    }
  }
}
