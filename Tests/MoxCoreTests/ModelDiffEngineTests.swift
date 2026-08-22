import Foundation
import Testing
@testable import MoxShared

/// Tests for the pure diff engine. The engine never touches the network —
/// it just decides per file whether to fetch or skip. v0.8's contract is
/// that size-equal files are unchanged (a stronger byte-level check would
/// require reading every local file; defer that to the post-write sha256).
@Suite("ModelDiffEngine")
struct ModelDiffEngineTests {

    private func entry(
        _ path: String,
        bytes: Int64,
        sha: String? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(path: path, sizeBytes: bytes, sha256: sha)
    }

    private func inventory(
        _ id: String = "test/model",
        files: [RemoteFileEntry] = [],
        revision: String? = "rev1"
    ) -> RemoteModelInventory {
        RemoteModelInventory(
            modelId: id,
            revision: revision,
            files: files,
            totalBytes: files.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    @Test("Empty local cache downloads everything")
    func emptyLocal() {
        let remote = self.inventory(files: [
            self.entry("config.json", bytes: 100),
            self.entry("model.safetensors", bytes: 5_000_000_000)
        ])
        let plan = ModelDiffEngine.plan(remote: remote, local: [:])
        #expect(plan.totalBytesToFetch == 5_000_000_100)
        #expect(plan.hasUpdates)
        #expect(plan.files.count == 2)
        #expect(plan.files.allSatisfy { $0.action == .download })
    }

    @Test("Matching sizes are unchanged (cheap path)")
    func matchingSizesUnchanged() {
        let remote = self.inventory(files: [
            self.entry("config.json", bytes: 100),
            self.entry("model.safetensors", bytes: 1_000)
        ])
        let local: [String: LocalFileMeta] = [
            "config.json": LocalFileMeta(sizeBytes: 100),
            "model.safetensors": LocalFileMeta(sizeBytes: 1_000)
        ]
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        #expect(plan.totalBytesToFetch == 0)
        #expect(!plan.hasUpdates)
        #expect(plan.files.allSatisfy { $0.action == .unchanged })
    }

    @Test("Size mismatch downloads the new file")
    func sizeMismatchDownloads() {
        let remote = self.inventory(files: [
            self.entry("model.safetensors", bytes: 2_000)
        ])
        let local: [String: LocalFileMeta] = [
            "model.safetensors": LocalFileMeta(sizeBytes: 1_000)
        ]
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        #expect(plan.totalBytesToFetch == 2_000)
        #expect(plan.files.first?.action == .sizeMismatch)
    }

    @Test("Remote with one new file + one unchanged shows partial fetch")
    func partialFetch() {
        let remote = self.inventory(files: [
            self.entry("config.json", bytes: 100),
            self.entry("new.safetensors", bytes: 500)
        ])
        let local: [String: LocalFileMeta] = [
            "config.json": LocalFileMeta(sizeBytes: 100)
        ]
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        #expect(plan.totalBytesToFetch == 500)
        #expect(plan.files.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, $0.action) })
        #expect(byPath["config.json"] == .unchanged)
        #expect(byPath["new.safetensors"] == .download)
    }

    @Test("Revision is propagated to the plan")
    func revisionPropagated() {
        let remote = self.inventory(revision: "abc123")
        let plan = ModelDiffEngine.plan(remote: remote, local: [:])
        #expect(plan.sourceRevision == "abc123")
    }

    @Test("Subdirectory paths match by basename")
    func subdirectoryPathMatches() {
        let remote = self.inventory(files: [
            self.entry("weights/model.safetensors", bytes: 1_000)
        ])
        let local: [String: LocalFileMeta] = [
            "model.safetensors": LocalFileMeta(sizeBytes: 1_000)
        ]
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        #expect(plan.totalBytesToFetch == 0)
    }

    @Test("Hash mismatch without size change is still cheap-path unchanged")
    func hashMismatchCheapPath() {
        // The diff engine's job is to identify files that *cannot* be a
        // byte-level match. Size-equal + size-only is enough to short-
        // circuit. If hashes disagree at write time the Downloader
        // surfaces the mismatch via sha256 verification, not the plan.
        let remote = self.inventory(files: [
            self.entry("model.safetensors", bytes: 100, sha: "deadbeef")
        ])
        let local: [String: LocalFileMeta] = [
            "model.safetensors": LocalFileMeta(sizeBytes: 100, sha256: "cafebabe")
        ]
        let plan = ModelDiffEngine.plan(remote: remote, local: local)
        #expect(plan.totalBytesToFetch == 0)
        #expect(plan.files.first?.action == .unchanged)
    }
}