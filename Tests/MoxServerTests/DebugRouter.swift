import Foundation
@testable import MoxServer
import Testing

@Suite("debug")
struct DebugRouter {
    @Test("check")
    func manualCheck() {
        let prefix = "/v1/models/"
        let suffix = "/load"
        let path = "/v1/models/foo/load"
        let modelId = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(modelId == "foo")
        print("id: \(modelId)")
    }
}
