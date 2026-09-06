import Foundation
import SwiftData

@Model final class ProbeRecord {
    @Attribute(.unique) var key: String
    var text: String
    init(key: String, text: String) { self.key = key; self.text = text }
}

@ModelActor actor ProbeStore {
    func insert() throws {
        modelContext.insert(ProbeRecord(key: "request-1", text: "interrupted"))
        try modelContext.save()
    }
    func records() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<ProbeRecord>()).map { $0.text }
    }
}

@main struct Probe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              ["write", "read"].contains(CommandLine.arguments[1]) else {
            throw NSError(domain: "SwiftDataProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: store-probe write|read STORE_PATH"])
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let schema = Schema([ProbeRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = ProbeStore(modelContainer: container)
        if CommandLine.arguments[1] == "write" { try await store.insert() }
        print(try await store.records())
    }
}
