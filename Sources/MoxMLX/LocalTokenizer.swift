import Foundation
import MLXLMCommon
import MoxDomain
import Tokenizers

struct LocalTokenizerLoader: TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    guard tokenizer.hasChatTemplate else {
      throw MoxError(.invalidModel, "A local chat template is required.")
    }
    return TokenizerAdapter(base: tokenizer)
  }
}
private struct TokenizerAdapter: MLXLMCommon.Tokenizer {
  let base: any Tokenizers.Tokenizer
  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    base.encode(text: text, addSpecialTokens: addSpecialTokens)
  }
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }
  func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
  var bosToken: String? { base.bosToken }
  var eosToken: String? { base.eosToken }
  var unknownToken: String? { base.unknownToken }
  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    try base.applyChatTemplate(
      messages: messages, tools: tools, additionalContext: additionalContext)
  }
}
