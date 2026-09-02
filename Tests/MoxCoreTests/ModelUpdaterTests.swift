import Foundation
import Testing
@testable import MoxCore
@testable import MoxShared

/// v0.8.3 closes the loop on `mox update`:
///   - downloads only the changed files (covered by diff engine tests)
///   - rewrites `sha256.txt` so the next diff pass sees the new bytes
///   - pins `revision` on `mox.json`
///   - reports progress against `plan.totalBytesToFetch`, not per-file
///
/// `Downloader` and `RemoteInventoryFetcher` are protocols, so we
/// stand up tiny in-memory mocks here instead of touching the network.
@Suite("ModelUpdater v0.8.3 close-the-loop")
struct ModelUpdaterTests {

    // MARK: - Mocks

    /// Returns the same canned inventory every call.
    struct StubFetcher: RemoteInventoryFetcher, Sendable {
        let inventory: RemoteModelInventory
        func fetch(modelId: String, revision: String?) async throws -> RemoteModelInventory {
            inventory
        }
    }

    /// Writes the URL's `lastPathComponent` payload bytes to `destination`.
    /// Reports a 0.5 + 1.0 progress tick pair so the cumulative tracker
    /// gets exercised.
    final class StubDownloader: Downloader, @unchecked Sendable {
        let payloads: [String: Data]
        private let lock = NSLock()
        private var recorded: [URL] = []

        init(payloads: [String: Data]) {
            self.payloads = payloads
        }

        nonisolated func download(
            from url: URL,
            to destination: URL,
            progress: (@Sendable (Double) -> Void)?
        ) async throws {
            // `withLock` is async-context safe; the recorded array
            // stays serialized through the closure.
            lock.withLock { recorded.append(url) }
            let name = url.lastPathComponent
            guard let data = payloads[name] else {
                throw DownloadError.downloadFailed("no payload for \(name)")
            }
            progress?(0.5)
            try data.write(to: destination)
            progress?(1.0)
        }

        func snapshotRecorded() -> [URL] {
            lock.withLock { recorded }
        }
    }

    // MARK: - Fixtures

    private func entry(
        _ path: String,
        bytes: Int64,
        sha: String? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(path: path, sizeBytes: bytes, sha256: sha)
    }

    private func inventory(
        _ id: String = "test/model",
        revision: String? = "rev1",
        files: [RemoteFileEntry]
    ) -> RemoteModelInventory {
        RemoteModelInventory(
            modelId: id,
            revision: revision,
            files: files,
            totalBytes: files.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    private func makeModelDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-updater-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeManifest(
        _ dir: URL,
        id: String = "test/model",
        source: ModelSource = .huggingface,
        revision: String? = nil
    ) throws {
        let manifest = ModelManifest(
            id: id,
            source: source,
            originalId: id,
            revision: revision
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("mox.json"), options: [.atomic])
    }

    private func readManifest(_ dir: URL) throws -> ModelManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("mox.json"))
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    // MARK: - Tests

    @Test("update downloads new files and rewrites sha256.txt")
    func rewritesSha256Manifest() async throws {
        let dir = try makeModelDir("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(dir, revision: "oldrev")

        // Pre-existing weights file with a known payload.
        let oldData = Data("old".utf8)
        try oldData.write(to: dir.appendingPathComponent("old.safetensors"))

        let newData = Data("new-weights-payload".utf8)
        let fetcher = StubFetcher(inventory: inventory(
            revision: "rev2",
            files: [
                entry("old.safetensors", bytes: Int64(oldData.count)),
                entry("new.safetensors", bytes: Int64(newData.count)),
            ]
        ))
        let downloader = StubDownloader(payloads: [
            "old.safetensors": oldData,
            "new.safetensors": newData,
        ])
        let updater = ModelUpdater(fetcher: fetcher, downloader: downloader)

        let plan = try await updater.update(
            modelId: "test/model",
            localDirectory: dir,
            revision: "rev2",
            progressHandler: nil
        )
        // Both files at the right size; the "old" one was already
        // byte-identical so the diff engine classifies it as
        // `unchanged` (cheap size match). Only `new.safetensors`
        // should have been downloaded.
        #expect(plan.hasUpdates)
        #expect(plan.sourceRevision == "rev2")
        let recorded = downloader.snapshotRecorded()
        #expect(recorded.count == 1)
        #expect(recorded.first?.lastPathComponent == "new.safetensors")

        // sha256.txt was rewritten; contains entries for both weight
        // files but NOT for mox.json / sha256.txt themselves.
        let shaBody = try String(contentsOf: dir.appendingPathComponent("sha256.txt"), encoding: .utf8)
        #expect(shaBody.contains("old.safetensors"))
        #expect(shaBody.contains("new.safetensors"))
        #expect(!shaBody.contains("mox.json"))
        #expect(!shaBody.contains("sha256.txt"))
    }

    @Test("update pins the new revision on mox.json")
    func pinsRevision() async throws {
        let dir = try makeModelDir("rev")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(dir, revision: "oldrev")

        let payload = Data("weights".utf8)
        let fetcher = StubFetcher(inventory: inventory(
            revision: "rev-new",
            files: [entry("w.safetensors", bytes: Int64(payload.count))]
        ))
        let downloader = StubDownloader(payloads: ["w.safetensors": payload])
        let updater = ModelUpdater(fetcher: fetcher, downloader: downloader)

        _ = try await updater.update(
            modelId: "test/model",
            localDirectory: dir,
            revision: nil,
            progressHandler: nil
        )
        let manifest = try readManifest(dir)
        #expect(manifest.revision == "rev-new")
        // Other fields preserved through the round-trip.
        #expect(manifest.id == "test/model")
        #expect(manifest.source == .huggingface)
    }

    @Test("update preserves an existing revision pin when remote returns nil")
    func preservesExistingRevision() async throws {
        let dir = try makeModelDir("keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(dir, revision: "pinned")

        // No changes — empty local, no files to fetch. Pass `nil`
        // revision through and expect the manifest's revision to
        // remain untouched.
        let fetcher = StubFetcher(inventory: inventory(revision: nil, files: []))
        let downloader = StubDownloader(payloads: [:])
        let updater = ModelUpdater(fetcher: fetcher, downloader: downloader)

        let plan = try await updater.update(
            modelId: "test/model",
            localDirectory: dir,
            revision: nil,
            progressHandler: nil
        )
        #expect(!plan.hasUpdates)
        let manifest = try readManifest(dir)
        #expect(manifest.revision == "pinned")
    }

    @Test("progress handler sees cumulative bytes against plan total")
    func cumulativeProgress() async throws {
        let dir = try makeModelDir("prog")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(dir)

        let a = Data(repeating: 0xAA, count: 100)
        let b = Data(repeating: 0xBB, count: 300)
        let fetcher = StubFetcher(inventory: inventory(
            revision: "rev",
            files: [
                entry("a.safetensors", bytes: Int64(a.count)),
                entry("b.safetensors", bytes: Int64(b.count)),
            ]
        ))
        let downloader = StubDownloader(payloads: [
            "a.safetensors": a,
            "b.safetensors": b,
        ])
        let updater = ModelUpdater(fetcher: fetcher, downloader: downloader)

        // Accumulate ticks through a class to keep the closure
        // non-mutating (Swift 6 strict concurrency forbids `var`
        // capture inside a @Sendable closure).
        let collector = TickCollector()
        _ = try await updater.update(
            modelId: "test/model",
            localDirectory: dir,
            revision: nil,
            progressHandler: { p in
                collector.append(p)
            }
        )
        let observed = collector.snapshot()
        // We saw at least one tick (the stub fires 0.5 + 1.0 per file).
        #expect(!observed.isEmpty)
        // Every tick's totalBytes must equal the plan total (400).
        // If the multi-file fix regresses, totalBytes would equal
        // entry.remoteBytes for the *current* file instead.
        let planTotal = Int64(400)
        for tick in observed {
            #expect(tick.totalBytes == planTotal)
            // And bytesDownloaded is cumulative (0..400), never
            // resetting to 0 at file boundaries.
            #expect(tick.bytesDownloaded >= 0)
            #expect(tick.bytesDownloaded <= planTotal)
        }
        // The last tick should be at-or-near the plan total.
        let last = observed.last!
        #expect(last.bytesDownloaded == planTotal)
    }
}

/// Thread-safe sink for `DownloadProgress` ticks delivered through
/// `@Sendable` closures. Plain array + NSLock is enough; this is
/// test-only.
final class TickCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [DownloadProgress] = []

    func append(_ p: DownloadProgress) {
        lock.withLock { ticks.append(p) }
    }

    func snapshot() -> [DownloadProgress] {
        lock.withLock { ticks }
    }
}