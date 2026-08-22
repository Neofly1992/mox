import SwiftUI

/// Shown when the GUI boots with `daemon.enabled = true` in config but the
/// daemon isn't reachable on `host:port`. The three buttons map to the
/// three resolution paths in `AppState`: spawn the daemon, fall back to
/// temporary mode, or exit.
///
/// Presented inline by `MoxApp` as a modal overlay. We intentionally do
/// not use `.alert` here — the body is informational rather than
/// confirmatory, and `.alert` truncates custom views on macOS 14.
struct DaemonModeDialog: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Mox daemon is not running")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("The daemon isn't reachable on \(appState.serverHost):\(appState.serverPort).")
                Text("Start the daemon for menu bar integration and to allow other OpenAI-compatible clients to connect, or use temporary mode for this session — `mox` will be spawned as a child process for each request.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            // HIG button order: cancel leftmost, primary rightmost. The
            // primary "Start daemon" gets `.defaultAction` so Return
            // triggers it; Cancel gets `.cancelAction` so Esc dismisses.
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    appState.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(appState.isModeChangeInFlight)

                Spacer()

                Button {
                    appState.useTemporaryMode()
                } label: {
                    Label("Temporary mode", systemImage: "terminal")
                }
                .disabled(appState.isModeChangeInFlight)

                Button {
                    Task { await appState.startDaemonAndConnect() }
                } label: {
                    Label("Start daemon", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.isModeChangeInFlight)
            }

            if appState.isModeChangeInFlight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}