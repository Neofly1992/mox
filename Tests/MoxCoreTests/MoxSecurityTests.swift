import Foundation
import Testing
@testable import MoxCore
import MoxShared

// Tests for the four download-safety fixes:
//
//   B1  ModelPathGuard rejects path-traversal file names.
//   B2  Mirror allowlist rejects unknown hosts.
//   B3  `mox pull foo --source mlx-community` resolves to `mlx-community/foo`,
//       not `mlx-community/mlx-community/foo`.
//   B4  listModels() reads `mox.json` for the source instead of guessing from
//       the directory name.

@Suite("Model download safety")
struct MoxSecurityTests {

    // MARK: - B1: path traversal

    @Test("ModelPathGuard rejects empty / absolute / relative-traversal names")
    func pathGuardRejectsUnsafeNames() throws {
        let parent = URL(fileURLWithPath: "/tmp/mox-test")

        let badNames: [String] = [
            "",
            "/etc/passwd",
            "~/sneaky",
            "../etc/passwd",
            "..",
            "foo/../bar",
            "a/b",
            "a\\b",
            "subdir/evil",
        ]
        for name in badNames {
            #expect(throws: ModelError.self) {
                _ = try ModelPathGuard.safeChild(parent: parent, name: name)
            }
        }
    }

    @Test("ModelPathGuard accepts ordinary file names")
    func pathGuardAcceptsOrdinaryNames() throws {
        let parent = URL(fileURLWithPath: "/tmp/mox-test")
        let okNames = ["config.json", "model.safetensors", "tokenizer.model"]
        for name in okNames {
            let child = try ModelPathGuard.safeChild(parent: parent, name: name)
            #expect(child.lastPathComponent == name)
            #expect(child.deletingLastPathComponent().path == parent.path)
        }
    }

    // MARK: - B2: mirror allowlist

    @Test("HuggingFaceSource accepts huggingface.co and hf-mirror.com")
    func huggingFaceAllowlistAccepts() throws {
        _ = try HuggingFaceSource(mirror: "https://huggingface.co")
        _ = try HuggingFaceSource(mirror: "https://hf-mirror.com")
        // nil mirror must always be allowed.
        _ = try HuggingFaceSource()
    }

    @Test("HuggingFaceSource rejects non-allowlisted hosts")
    func huggingFaceAllowlistRejects() {
        for mirror in [
            "https://evil.example.com",
            "https://huggingface.co.evil.example.com",
            "not a url",
            "https://",
        ] {
            #expect(throws: MirrorError.self) {
                _ = try HuggingFaceSource(mirror: mirror)
            }
        }
    }

    @Test("ModelScopeSource only accepts modelscope.cn")
    func modelScopeAllowlist() throws {
        _ = try ModelScopeSource(mirror: "https://modelscope.cn")
        _ = try ModelScopeSource()
        #expect(throws: MirrorError.self) {
            _ = try ModelScopeSource(mirror: "https://modelscope.cn.evil.example")
        }
    }

    // MARK: - B3: mlx-community double prefix is gone

    @Test("mlx-community source resolves to single namespace prefix")
    func mlxCommunitySinglePrefix() {
        // The fix: pullModel for `.mlxCommunity` must reuse
        // HuggingFaceSource.resolveModelId without an additional
        // `mlx-community/` wrap. HuggingFaceSource already prefixes the
        // namespace for ids that lack a `/`.
        let resolved = try? HuggingFaceSource().resolveModelId("foo")
        #expect(resolved == "mlx-community/foo")
    }

    @Test("pullModel with mlx-community source produces mlx-community-foo directory")
    func pullModelMlxCommunityDirName() async throws {
        // We don't want a real network call here, but pullModel's
        // directory-existence check happens BEFORE the download, so we
        // can probe resolvedId by pre-creating the directory it would
        // try to use.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mox-b3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = ModelManager(modelsDirectory: dir.path)
        // Pre-create the directory the *correct* implementation would try
        // to use: "mlx-community-foo". If the fix is in place, pullModel
        // will throw `alreadyExists` here, indicating it computed
        // resolvedId = "mlx-community/foo" → sanitizedId = "mlx-community-foo".
        // If the bug were present, it would try "mlx-community-mlx-community-foo"
        // and instead throw `alreadyExists` on a directory that doesn't exist.
        let expectedDir = dir.appendingPathComponent("mlx-community-foo")
        try FileManager.default.createDirectory(at: expectedDir, withIntermediateDirectories: true)

        do {
            _ = try await manager.pullModel(id: "foo", source: .mlxCommunity)
            Issue.record("expected alreadyExists error")
        } catch let error as ModelError {
            switch error {
            case .alreadyExists(let id):
                #expect(id == "mlx-community/foo",
                        "expected single-prefix id, got \(id)")
            default:
                Issue.record("expected .alreadyExists, got \(error)")
            }
        }

        // Sanity: the double-prefix directory must NOT have been touched.
        let doublePrefix = dir.appendingPathComponent("mlx-community-mlx-community-foo")
        #expect(!FileManager.default.fileExists(atPath: doublePrefix.path))
    }

    // MARK: - B4: listModels uses mox.json for source

    @Test("listModels reads source from mox.json manifest")
    func listModelsReadsManifest() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mox-b4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a model directory with a manifest claiming it's a
        // ModelScope model.
        let modelDir = dir.appendingPathComponent("my-org-some-model")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let manifest = ModelManifest(
            id: "my-org/some-model",
            source: .modelscope,
            originalId: "some-model"
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: modelDir.appendingPathComponent("mox.json"))

        // Seed a fake weight file so the directory has a non-zero size.
        try Data("fake weights".utf8).write(to: modelDir.appendingPathComponent("weights.bin"))

        let manager = ModelManager(modelsDirectory: dir.path)
        await manager.invalidateCache()
        let models = try await manager.listModels()
        guard let entry = models.first(where: { $0.id == "my-org/some-model" }) else {
            Issue.record("manifested model not listed")
            return
        }
        #expect(entry.source == .modelscope,
                "manifest source must be honored, got \(entry.source)")
        #expect(entry.path.hasSuffix("my-org-some-model"))
    }

    @Test("listModels falls back to .unknown when no manifest is present")
    func listModelsUnknownFallback() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mox-b4-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacyDir = dir.appendingPathComponent("legacy-model-dir")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacyDir.appendingPathComponent("weights.bin"))

        let manager = ModelManager(modelsDirectory: dir.path)
        await manager.invalidateCache()
        let models = try await manager.listModels()
        guard let entry = models.first(where: { $0.id == "legacy-model-dir" }) else {
            Issue.record("legacy directory not listed")
            return
        }
        #expect(entry.source == .unknown,
                "no-manifest directory must surface as .unknown, got \(entry.source)")
    }
}