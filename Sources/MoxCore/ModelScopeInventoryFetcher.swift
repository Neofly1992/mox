import Foundation
import MoxShared

/// ModelScope tree adapter. Hits
/// `https://modelscope.cn/api/v1/models/{repo_id}/repo/files?Recursive=True`
/// and turns the `Data.Files[]` payload into `RemoteModelInventory`.
///
/// Wire shape (one entry):
/// ```
/// {
///   "Name": "config.json",
///   "Path": "config.json",
///   "Size": 659,
///   "Sha256": "18e18afca...",
///   "Revision": "13448952dbdab7a1627d0680ecd207535d889a23",
///   ...
/// }
/// ```
/// The top-level `Revision` is the commit hash pinned at the moment of
/// the listing — the same role HuggingFace's `sha` plays in the HF
/// adapter. We surface it as `RemoteModelInventory.revision` so the
/// diff engine / manifest pin work without per-source special cases.
public struct ModelScopeInventoryFetcher: RemoteInventoryFetcher {
    public let mirrorBase: String?
    public init(mirrorBase: String? = nil) {
        self.mirrorBase = mirrorBase
    }

    public func fetch(modelId: String, revision: String?) async throws -> RemoteModelInventory {
        let base = mirrorBase ?? "https://modelscope.cn"
        var components = URLComponents(string: "\(base)/api/v1/models/\(modelId)/repo/files")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "True"),
        ]
        if let revision { queryItems.append(URLQueryItem(name: "Revision", value: revision)) }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RemoteFetcherError.malformedResponse
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFetcherError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw RemoteFetcherError.badStatus(http.statusCode)
        }
        return try Self.parse(data, modelId: modelId)
    }

    /// Pure wire→inventory decoder. Public so tests can feed canned
    /// JSON without standing up a `URLSession` stub. Mirrors what
    /// `fetch(modelId:revision:)` does after the HTTP layer.
    public static func parse(_ data: Data, modelId: String) throws -> RemoteModelInventory {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["Data"] as? [String: Any],
              let rawFiles = payload["Files"] as? [[String: Any]]
        else {
            throw RemoteFetcherError.malformedResponse
        }
        let pinnedRevision = payload["Revision"] as? String
        let files: [RemoteFileEntry] = rawFiles.compactMap { entry in
            guard let path = entry["Path"] as? String,
                  let size = (entry["Size"] as? Int64) ?? (entry["Size"] as? NSNumber)?.int64Value
            else { return nil }
            let sha = entry["Sha256"] as? String
            return RemoteFileEntry(path: path, sizeBytes: size, sha256: sha)
        }
        return RemoteModelInventory(
            modelId: modelId,
            revision: pinnedRevision,
            files: files,
            totalBytes: files.reduce(0) { $0 + $1.sizeBytes }
        )
    }
}