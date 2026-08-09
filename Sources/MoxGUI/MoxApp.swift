// v0.3 ships the GUI as a bare executable launched with `swift run mox-gui`.
//
// The proper macOS .app bundle (Info.plist, code signing, sandbox
// entitlements, Hardened Runtime, notarization) is a v0.5 concern — adding
// it now would pull in Developer ID + `codesign` + `notarytool` plumbing
// before the GUI has any production users. The bare executable compiles,
// launches a SwiftUI window, and is enough to exercise the 4-tab layout,
// status bar registration paths, mode-detection dialog, and Settings tab
// in v0.3.

import MoxGUIClient
import MoxShared
import SwiftUI

@main
struct MoxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Mox") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Boot-time setup: read config, probe the daemon, and
                    // either connect, fall back to temporary mode, or surface
                    // the user-choice dialog. Model loading waits until the
                    // mode decision lands so the GUI never probes a stale
                    // backend.
                    await appState.bootstrap()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // ⌘N — new conversation. We intentionally *replace* the default
            // "New" menu item rather than append: Mox doesn't have documents.
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    appState.startNewConversation()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

/// Top-level scene content. Renders `MainWindow` normally and overlays the
/// `DaemonModeDialog` while bootstrap is waiting on a user decision.
private struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            MainWindow()
            if appState.showDaemonDialog {
                // Dim + center. The overlay sits above the tab content so
                // the user can't poke at a half-initialised client behind
                // the dialog.
                Color.black.opacity(0.35).ignoresSafeArea()
                DaemonModeDialog()
                    .background(.regularMaterial)
                    .cornerRadius(12)
                    .shadow(radius: 18)
                    .padding(40)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.showDaemonDialog)
    }
}

/// Shared, observable application state. Owns the `MoxAPIClient`, the
/// status bar controller, the in-memory conversation model, and the persistent
/// settings that bind directly to the Settings tab UI.
///
/// Persistence note: configuration values mirror `~/.mox/config.json` in
/// memory and are written back as the user changes them. SQLite-backed
/// conversation history arrives in v0.5 — for v0.3, conversations die with
/// the process.
@MainActor
final class AppState: ObservableObject {
    @Published var mode: BackendMode = .undetected
    @Published var models: [ModelInfo] = []
    @Published var currentConversation: Conversation?
    @Published var startupError: String?

    /// Whether the daemon is enabled in `~/.mox/config.json`. Toggling this
    /// from Settings persists and triggers a mode-change attempt.
    @Published var daemonEnabled: Bool = false

    /// Server endpoint. Read from config at bootstrap, editable in Settings,
    /// persisted back to config on change.
    @Published var serverHost: String = "127.0.0.1"
    @Published var serverPort: Int = 11555

    /// Inference defaults. Same persistence shape as server fields.
    @Published var maxTokens: Int = 2048
    @Published var temperature: Double = 0.7

    /// Visible while `bootstrap` is waiting on a user choice about the missing
    /// daemon. Flips off once the user picks one of the three options in
    /// `DaemonModeDialog`.
    @Published var showDaemonDialog: Bool = false

    /// True while `applyModeChange` or `startDaemonAndConnect` is mid-flight,
    /// so the Settings picker + dialog buttons can show a spinner and refuse
    /// re-entry.
    @Published private(set) var isModeChangeInFlight: Bool = false

    /// The client the GUI uses. Concrete type is injected at bootstrap based
    /// on whether a daemon was reachable; we keep the protocol type here so
    /// the rest of the app doesn't need a switch.
    private(set) var client: MoxAPIClient?

    /// Configured at bootstrap. Only constructed when we actually land in
    /// `.daemon` mode; nil in temporary mode and during the dialog.
    private var statusBar: StatusBarController?

    /// Dialect of how Mox is currently being driven.
    enum BackendMode: Equatable {
        case undetected
        case daemon
        case temporary
    }

    // MARK: - Lifecycle

    /// Probe the daemon, decide a mode, and surface the user-choice dialog
    /// when the daemon is missing but expected. Idempotent within a single
    /// boot — re-calling is safe but a no-op.
    func bootstrap() async {
        // 1. Load config (typed + raw for daemon.enabled).
        let raw = loadRawConfig()
        if let enabled = (raw["daemon"] as? [String: Any])?["enabled"] as? Bool {
            daemonEnabled = enabled
        }
        let config = loadAppConfig()
        serverHost = config.server.host
        serverPort = config.server.port
        maxTokens = config.defaults.maxTokens
        temperature = config.defaults.temperature

        let baseURLString = "http://\(serverHost):\(serverPort)"
        guard let url = URL(string: baseURLString) else {
            startupError = "Invalid server URL: \(baseURLString)"
            return
        }

        // 2. Probe. Three-way branch.
        isModeChangeInFlight = true
        defer { isModeChangeInFlight = false }

        if await probeDaemon(at: url) {
            await enterDaemonMode(at: url, activateStatusBar: daemonEnabled)
            await loadModels()
            return
        }

        if daemonEnabled {
            // Daemon expected but unreachable: ask the user what to do. The
            // dialog calls back into one of the three handlers below; nothing
            // else happens until they pick.
            showDaemonDialog = true
            return
        }

        // Daemon not expected: temporary mode is the obvious answer; no
        // dialog required.
        await enterTemporaryMode()
        await loadModels()
    }

    // MARK: - Dialog actions

    /// "Start daemon" — spawn `mox-server start`, wait for it to come up,
    /// then connect. Falls back to temporary mode if the daemon never reaches
    /// /health within the wait budget.
    func startDaemonAndConnect() async {
        showDaemonDialog = false
        isModeChangeInFlight = true
        defer { isModeChangeInFlight = false }

        do {
            try await launchDaemon()
        } catch {
            startupError = "Failed to start daemon: \(error.localizedDescription). Falling back to temporary mode."
            await enterTemporaryMode()
            await loadModels()
            return
        }

        let baseURLString = "http://\(serverHost):\(serverPort)"
        guard let url = URL(string: baseURLString) else {
            startupError = "Invalid server URL: \(baseURLString)"
            return
        }

        if await waitForDaemon(at: url) {
            await enterDaemonMode(at: url, activateStatusBar: true)
            await loadModels()
        } else {
            startupError = "Daemon did not respond on \(serverHost):\(serverPort) within \(Int(Self.daemonWaitSeconds))s. Falling back to temporary mode."
            await enterTemporaryMode()
            await loadModels()
        }
    }

    /// "Use temporary mode" — skip the daemon entirely for this session.
    func useTemporaryMode() {
        showDaemonDialog = false
        Task {
            isModeChangeInFlight = true
            defer { isModeChangeInFlight = false }
            await enterTemporaryMode()
            await loadModels()
        }
    }

    /// "Cancel" — the user doesn't want the GUI right now. v0.3 has no
    /// background-only use case, so exiting the process is the cleanest way
    /// to honour the intent.
    func cancel() {
        // Reset state so any observer-side cleanup is in a known state, then
        // exit. Don't trigger any other async work — we're done.
        showDaemonDialog = false
        exit(0)
    }

    // MARK: - Settings-driven mode change

    /// Persist the daemon-enabled flag and reconcile the live mode against
    /// the new desired state. Called by the Settings picker `onChange`.
    /// `enabled` is the *desired* state coming from the UI.
    func applyModeChange(enabled: Bool) async {
        // Mirror the new flag locally first so the UI feels instant.
        daemonEnabled = enabled
        writeConfig()

        isModeChangeInFlight = true
        defer { isModeChangeInFlight = false }

        if enabled {
            // Want daemon: connect if one is already up, otherwise spawn.
            let baseURLString = "http://\(serverHost):\(serverPort)"
            guard let url = URL(string: baseURLString) else { return }
            if await probeDaemon(at: url) {
                await enterDaemonMode(at: url, activateStatusBar: true)
                await loadModels()
                return
            }
            do {
                try await launchDaemon()
            } catch {
                startupError = "Failed to start daemon: \(error.localizedDescription). Staying in temporary mode."
                if mode != .temporary { await enterTemporaryMode() }
                await loadModels()
                return
            }
            if await waitForDaemon(at: url) {
                await enterDaemonMode(at: url, activateStatusBar: true)
                await loadModels()
            } else {
                startupError = "Daemon did not respond on \(serverHost):\(serverPort) within \(Int(Self.daemonWaitSeconds))s. Staying in temporary mode."
                if mode != .temporary { await enterTemporaryMode() }
                await loadModels()
            }
        } else {
            // Don't want daemon. Stop whatever is running, then run as
            // temporary.
            await stopDaemon()
            await enterTemporaryMode()
            await loadModels()
        }
    }

    /// Persist host/port/inference defaults whenever the Settings editor
    /// changes them. The daemon itself isn't restarted here — the user has
    /// to toggle daemon mode to re-probe with new coordinates.
    func applyServerChange() {
        writeConfig()
    }

    func applyDefaultsChange() {
        writeConfig()
    }

    // MARK: - Conversation helper

    func startNewConversation() {
        currentConversation = Conversation()
    }

    // MARK: - Private: mode transitions

    private func enterDaemonMode(at url: URL, activateStatusBar: Bool) async {
        mode = .daemon
        client = HTTPAPIClient(baseURL: url)
        if activateStatusBar {
            if statusBar == nil { statusBar = StatusBarController() }
            statusBar?.activate(currentModel: models.first?.name)
        }
    }

    private func enterTemporaryMode() async {
        mode = .temporary
        client = MoxAPIClientFactory.defaultProcessClient()
        // No status bar in temporary mode — there's no daemon to surface.
        statusBar = nil
    }

    // MARK: - Private: model loading

    private func loadModels() async {
        do {
            models = try await client?.listModels() ?? []
        } catch {
            // Listing failure isn't fatal — the GUI can still render; just
            // surface the empty state.
            models = []
        }
    }

    // MARK: - Private: daemon probing

    /// Single-shot probe of `/health`. Used both at bootstrap time and after
    /// a user toggles daemon mode on.
    private func probeDaemon(at url: URL) async -> Bool {
        guard let healthURL = URL(string: "/health", relativeTo: url) else { return false }
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    /// Polls `/health` until it succeeds or `daemonWaitSeconds` elapses.
    private func waitForDaemon(at url: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.daemonWaitSeconds)
        while Date() < deadline {
            if await probeDaemon(at: url) { return true }
            try? await Task.sleep(nanoseconds: Self.daemonPollIntervalNanos)
        }
        return false
    }

    private static let daemonWaitSeconds: TimeInterval = 10
    private static let daemonPollIntervalNanos: UInt64 = 250_000_000 // 0.25s

    // MARK: - Private: process lifecycle for mox-server

    /// Spawns `mox-server start`. Failures (binary missing, launchctl
    /// refusing, etc.) bubble up so the caller can fall back to temporary
    /// mode with a clear error message.
    private func launchDaemon() async throws {
        let binary = Self.findMoxServerBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["start"]
        // Drain stdout/stderr so the child doesn't block on a full pipe;
        // we don't need its output here.
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw error
        }
        // `mox-server start` returns immediately after handing off to
        // launchctl. If launchctl never loaded the plist (e.g. it doesn't
        // exist on this machine), the process exits quickly with a non-zero
        // status; surface that as a startup error.
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "MoxGUI",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "mox-server start exited with status \(proc.terminationStatus). Is the launchd plist installed (mox-server install)?"]
            )
        }
    }

    /// Best-effort `mox-server stop`. Absence of the binary or of the launchd
    /// label are not considered fatal — we just won't leave a process behind.
    private func stopDaemon() async {
        let binary = Self.findMoxServerBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["stop"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Private: config I/O

    /// Parses the typed config the rest of the app cares about. Falls back
    /// to defaults if the file is missing or undecodable.
    private func loadAppConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: Self.configURL()) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    /// Loads the full config dictionary so we can read top-level keys
    /// (`daemon.enabled`) that `AppConfig` doesn't model in v0.3.
    private func loadRawConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.configURL()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// Write the current state of all settings back to disk. Delegates the
    /// round-trip to `MoxGUIClient.MoxGUIConfig.write` so the logic stays
    /// unit-testable.
    func writeConfig() {
        do {
            _ = try MoxGUIClient.MoxGUIConfig.write(
                to: Self.configURL(),
                host: serverHost,
                port: serverPort,
                maxTokens: maxTokens,
                temperature: temperature,
                daemonEnabled: daemonEnabled,
                existing: loadRawConfig()
            )
        } catch {
            startupError = "Failed to write config: \(error.localizedDescription)"
        }
    }

    private static func configURL() -> URL {
        URL(fileURLWithPath: NSString(string: "~/.mox/config.json").expandingTildeInPath)
    }

    /// Walks the conventional install locations for `mox-server`. The pure
    /// logic lives in `MoxGUIClient.MoxGUIConfig.findMoxServerBinary` so it
    /// can be tested without spinning up SwiftUI.
    static func findMoxServerBinary() -> String {
        MoxGUIClient.MoxGUIConfig.findMoxServerBinary()
    }
}

/// In-memory conversation. v0.5 swaps this out for a SQLite-backed
/// implementation; the SwiftUI surface stays the same.
struct Conversation: Identifiable {
    let id = UUID()
    var title: String = "New Chat"
    var modelId: String?
    var messages: [ChatMessage] = []
}
