import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// v0.8.3+ — ModelScope tree adapter. The fetcher hits
/// `https://modelscope.cn/api/v1/models/{repo_id}/repo/files?Recursive=True`
/// and turns the `Data.Files[]` payload into `RemoteModelInventory`.
///
/// The wire decoder is exposed as `ModelScopeInventoryFetcher.parse(_:modelId:)`
/// so tests can feed canned JSON without standing up a `URLSession` stub.
@Suite("ModelScopeInventoryFetcher")
struct ModelScopeInventoryFetcherTests {

    /// Build a JSON payload matching ModelScope's `/api/v1/models/{id}/repo/files`
    /// response shape, parameterised by the entry list.
    private func wire(
        revision: String?,
        files: [(path: String, size: Int64, sha: String?)]
    ) throws -> Data {
        let rawFiles: [[String: Any]] = files.map { entry in
            var dict: [String: Any] = [
                "Path": entry.path,
                "Size": entry.size,
            ]
            if let sha = entry.sha { dict["Sha256"] = sha }
            return dict
        }
        var payload: [String: Any] = ["Files": rawFiles]
        if let revision { payload["Revision"] = revision }
        let topLevel: [String: Any] = ["Code": 200, "Data": payload]
        return try JSONSerialization.data(withJSONObject: topLevel)
    }

    @Test("parse decodes a single-file response and pins the revision")
    func singleFile() throws {
        let data = try wire(
            revision: "abc123def",
            files: [(path: "config.json", size: 659, sha: "18e18afca")]
        )
        let inv = try ModelScopeInventoryFetcher.parse(data, modelId: "Qwen/Qwen2.5-0.5B-Instruct")
        #expect(inv.revision == "abc123def")
        #expect(inv.files.count == 1)
        let f = inv.files.first!
        #expect(f.path == "config.json")
        #expect(f.sizeBytes == 659)
        #expect(f.sha256 == "18e18afca")
    }

    @Test("parse accepts size as NSNumber (JSONSerialization default)")
    func sizeAsNSNumber() throws {
        // JSONSerialization writes integers as NSNumber; downstream
        // we coerce via `(entry["Size"] as? Int64) ?? (entry["Size"]
        // as? NSNumber)?.int64Value`. This test pins the NSNumber
        // path so the coercion can't regress.
        let topLevel: [String: Any] = [
            "Code": 200,
            "Data": [
                "Revision": "rev-num",
                "Files": [["Path": "x.safetensors", "Size": NSNumber(value: 42)]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: topLevel)
        let inv = try ModelScopeInventoryFetcher.parse(data, modelId: "any/model")
        #expect(inv.files.first?.sizeBytes == 42)
    }

    @Test("parse tolerates missing revision and missing sha256")
    func lenientFields() throws {
        let topLevel: [String: Any] = [
            "Code": 200,
            "Data": [
                "Files": [["Path": "x.safetensors", "Size": 10]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: topLevel)
        let inv = try ModelScopeInventoryFetcher.parse(data, modelId: "any/model")
        #expect(inv.revision == nil)
        #expect(inv.files.first?.sha256 == nil)
        #expect(inv.totalBytes == 10)
    }

    @Test("parse drops entries without a Path or Size")
    func dropsInvalidEntries() throws {
        let topLevel: [String: Any] = [
            "Code": 200,
            "Data": [
                "Files": [
                    ["Path": "good", "Size": 100],
                    ["Size": 200],                   // missing Path
                    ["Path": "no-size"],            // missing Size
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: topLevel)
        let inv = try ModelScopeInventoryFetcher.parse(data, modelId: "any/model")
        #expect(inv.files.count == 1)
        #expect(inv.files.first?.path == "good")
    }

    @Test("parse rejects a non-{Code,Data} envelope")
    func rejectsBadEnvelope() throws {
        let data = try JSONSerialization.data(withJSONObject: ["Code": 200])
        #expect(throws: RemoteFetcherError.self) {
            _ = try ModelScopeInventoryFetcher.parse(data, modelId: "any/model")
        }
    }
}