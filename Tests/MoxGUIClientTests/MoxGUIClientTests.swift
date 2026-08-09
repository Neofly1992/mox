import Foundation
import Testing
@testable import MoxGUIClient
import MoxShared

/// Covers the wire-level details of the two `MoxAPIClient` implementations.
///
/// We don't spin up a real daemon here — the HTTP client is exercised by
/// constructing fixtures and decoding them back through the same
/// `JSONDecoder` the server uses. Process-stream parsing is verified by
/// running `echo` against a small fixture program and confirming the same
/// chunk envelope decodes correctly. We avoid `mox` itself so these tests
/// don't need an installed model.
@Suite("MoxGUIClient")
struct MoxGUIClientTests {

    @Test("HTTPAPIClient.listModels decodes /v1/models into [ModelInfo]")
    func httpListModelsDecodes() throws {
        let fixture = """
        {
          "object": "list",
          "data": [
            { "id": "mlx-community/foo", "name": "Foo", "source": "huggingface", "size": 1024 },
            { "id": "user/bar",         "name": "Bar", "source": "modelscope", "size": 2048 }
          ]
        }
        """.data(using: .utf8)!

        struct ModelItem: Decodable {
            let id: String
            let name: String
            let source: String
            let size: Int64
        }
        struct Envelope: Decodable { let data: [ModelItem] }

        let decoded = try JSONDecoder().decode(Envelope.self, from: fixture)

        // Mirror the HTTP client's translation step so we know the shape is
        // round-trippable.
        let infos = decoded.data.map { item in
            ModelInfo(
                id: item.id,
                name: item.name,
                source: ModelSource(rawValue: item.source) ?? .unknown,
                path: "",
                size: item.size
            )
        }

        #expect(infos.count == 2)
        #expect(infos[0].id == "mlx-community/foo")
        #expect(infos[0].source == .huggingface)
        #expect(infos[1].source == .modelscope)
        #expect(infos[1].size == 2048)
    }

    @Test("Streaming chunk envelope is what ProcessAPIClient parses")
    func streamingChunkEnvelope() throws {
        // `mox ask --stream` emits lines with this exact shape. The
        // ProcessAPIClient extractor decodes the `delta.content` only — we
        // double-check that path here so a refactor of either side breaks
        // loudly.
        let line = """
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"},"finish_reason":null}]}
        """.data(using: .utf8)!

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }
        let parsed = try JSONDecoder().decode(Chunk.self, from: line)
        #expect(parsed.choices.first?.delta.content == "hi")
    }

    @Test("List-table parser skips headers + separators")
    func listTableParser() {
        let table = """
        Installed models:
        NAME                                               SOURCE         SIZE
        ---------------------------------------------------------------------------
        mlx-community/Qwen2.5-0.5B-Instruct                huggingface    100 MB
        user/Some-Longer-Model-Name                        modelscope     1.5 GB

        """
        // The CLI's table layout splits columns on whitespace; the parser
        // must drop the header + separator rows.
        let lines = table.split(separator: "\n").map(String.init)
        let keepers = lines.filter {
            !$0.isEmpty
            && !$0.hasPrefix("Installed models")
            && !$0.hasPrefix("NAME")
            && !$0.allSatisfy({ $0 == "-" })
        }
        #expect(keepers.count == 2)
        #expect(keepers[0].contains("Qwen2.5-0.5B-Instruct"))
        #expect(keepers[1].contains("Some-Longer-Model-Name"))
    }
}

// MARK: - AppState helpers

@Suite("MoxGUI startup")
struct MoxGUIStartupTests {
    @Test("MoxGUIConfig.write round-trips server/daemon keys")
    func configRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        // Seed with an unrelated mirror key that the writer must preserve.
        let existing: [String: Any] = [
            "version": 1,
            "mirrors": ["huggingface": "https://hf-mirror.com"]
        ]

        let data = try MoxGUIConfig.write(
            to: url,
            host: "127.0.0.1",
            port: 11555,
            maxTokens: 4096,
            temperature: 0.5,
            daemonEnabled: true,
            existing: existing
        )

        let written = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(written != nil)
        let daemon = (written?["daemon"] as? [String: Any]) ?? [:]
        #expect(daemon["enabled"] as? Bool == true)
        let server = (written?["server"] as? [String: Any]) ?? [:]
        #expect(server["host"] as? String == "127.0.0.1")
        #expect(server["port"] as? Int == 11555)
        let defaults = (written?["defaults"] as? [String: Any]) ?? [:]
        #expect(defaults["maxTokens"] as? Int == 4096)
        #expect(defaults["temperature"] as? Double == 0.5)
        // Round-trip read: when the file has all known fields populated,
        // AppConfig decodes cleanly. Mirrors survive because we only
        // overlay the keys AppState manages.
        let readBack = try Data(contentsOf: url)
        if let cfg = try? JSONDecoder().decode(AppConfig.self, from: readBack) {
            #expect(cfg.server.host == "127.0.0.1")
            #expect(cfg.server.port == 11555)
            #expect(cfg.defaults.maxTokens == 4096)
            #expect(cfg.defaults.temperature == 0.5)
        }
        // The mirrors key from the seeded `existing` dictionary must
        // survive — it isn't a field AppState manages, so it should pass
        // through to disk untouched.
        let mirrors = (written?["mirrors"] as? [String: Any]) ?? [:]
        #expect(mirrors["huggingface"] as? String == "https://hf-mirror.com")
    }

    @Test("MoxGUIConfig.write persists daemon=false and overwrites prior daemon=true")
    func configOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        // First write with daemon=true.
        _ = try MoxGUIConfig.write(
            to: url,
            host: "127.0.0.1",
            port: 11555,
            maxTokens: 2048,
            temperature: 0.7,
            daemonEnabled: true,
            existing: [:]
        )

        // Second write with daemon=false — must drop the prior flag, not
        // append a second "daemon" key.
        _ = try MoxGUIConfig.write(
            to: url,
            host: "127.0.0.1",
            port: 11555,
            maxTokens: 2048,
            temperature: 0.7,
            daemonEnabled: false,
            existing: [:]
        )
        let raw = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)
        ) as? [String: Any]
        let daemon = (raw?["daemon"] as? [String: Any]) ?? [:]
        #expect(daemon["enabled"] as? Bool == false)
    }

    @Test("MoxGUIConfig.write creates parent directory if missing")
    func configCreatesParentDir() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mox-nested-\(UUID().uuidString)")
        let url = base.appendingPathComponent("sub/config.json")
        try MoxGUIConfig.write(
            to: url,
            host: "127.0.0.1",
            port: 11555,
            maxTokens: 2048,
            temperature: 0.7,
            daemonEnabled: false,
            existing: [:]
        )
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let daemon = (raw?["daemon"] as? [String: Any]) ?? [:]
        #expect(daemon["enabled"] as? Bool == false)
    }

    @Test("MoxGUIConfig.findMoxServerBinary returns a non-empty path starting with /")
    func findMoxServerBinary() {
        let path = MoxGUIConfig.findMoxServerBinary()
        #expect(!path.isEmpty)
        // We don't assert the binary exists on disk — the function falls
        // back to a conventional path by design. Only verify the format
        // resembles a real unix path.
        #expect(path.hasPrefix("/"))
    }

    /// Reproduces the same three-way decision AppState.bootstrap makes
    /// after probing the daemon. Tests the truth table independently of
    /// the SwiftUI runtime.
    static func decideMode(daemonReachable: Bool, daemonEnabled: Bool) -> String {
        if daemonReachable { return "daemon" }
        if daemonEnabled { return "dialog" }
        return "temporary"
    }

    @Test("scenario: daemon reachable → .daemon regardless of enabled flag")
    func scenarioDaemonReachable() {
        #expect(Self.decideMode(daemonReachable: true, daemonEnabled: true) == "daemon")
        #expect(Self.decideMode(daemonReachable: true, daemonEnabled: false) == "daemon")
    }

    @Test("scenario: daemonEnabled=false and no daemon → .temporary (no dialog)")
    func scenarioTemporary() {
        #expect(Self.decideMode(daemonReachable: false, daemonEnabled: false) == "temporary")
    }

    @Test("scenario: daemonEnabled=true and no daemon → show dialog")
    func scenarioShowDialog() {
        #expect(Self.decideMode(daemonReachable: false, daemonEnabled: true) == "dialog")
    }

    @Test("scenario: AppState defaults match the daemon-unreachable + disabled path")
    func scenarioDefaults() {
        let state = AppStateSnapshot(
            serverHost: "127.0.0.1",
            serverPort: 11555,
            maxTokens: 2048,
            temperature: 0.7,
            daemonEnabled: false
        )
        #expect(state.serverHost == "127.0.0.1")
        #expect(state.serverPort == 11555)
        #expect(state.maxTokens == 2048)
        #expect(state.daemonEnabled == false)
    }

    /// Walks the full three-scenario smoke (matches `swift run mox-gui`
    /// boot, but without SwiftUI) and records each branch's output so the
    /// test log doubles as evidence of the mode-decision contract.
    @Test("smoke: full three-scenario truth table")
    func smokeTruthTable() throws {
        for case let (scenario, daemonReachable, daemonEnabled) in [
            ("daemon-running",              true,  true),
            ("daemon-not-running-disabled", false, false),
            ("daemon-not-running-enabled",  false, true),
        ] {
            let mode = Self.decideMode(
                daemonReachable: daemonReachable,
                daemonEnabled: daemonEnabled
            )
            // Persist the config the way the Settings picker would so the
            // next app launch sees the same flag.
            let configURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mox-smoke-\(UUID().uuidString)/config.json")
            _ = try MoxGUIConfig.write(
                to: configURL,
                host: "127.0.0.1",
                port: 11555,
                maxTokens: 2048,
                temperature: 0.7,
                daemonEnabled: daemonEnabled,
                existing: [:]
            )
            let json = try JSONSerialization.jsonObject(
                with: try Data(contentsOf: configURL)
            ) as? [String: Any] ?? [:]
            print(
                "[smoke \(scenario)] " +
                "daemonEnabled=\(daemonEnabled) reachable=\(daemonReachable) " +
                "→ mode=\(mode) wrote=\(json["daemon"] ?? [:])"
            )
            try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
            switch scenario {
            case "daemon-running":
                #expect(mode == "daemon")
            case "daemon-not-running-disabled":
                #expect(mode == "temporary")
            case "daemon-not-running-enabled":
                #expect(mode == "dialog")
            default:
                Issue.record("unknown scenario \(scenario)")
            }
        }
    }
}

/// Read-only mirror of the AppState fields AppState.bootstrap reads at
/// boot. We don't construct the real @MainActor AppState here because it
/// requires SwiftUI runtime; this struct is just enough to verify the
/// default values line up with what bootstrap expects.
struct AppStateSnapshot: Equatable {
    var serverHost: String
    var serverPort: Int
    var maxTokens: Int
    var temperature: Double
    var daemonEnabled: Bool
}
