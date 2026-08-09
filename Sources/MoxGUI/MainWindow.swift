import MoxGUIClient
import MoxShared
import SwiftUI

/// Top-level window chrome. v0.3 ships four tabs as placeholders; the
/// Chats tab carries the conversation list + detail skeleton, the others
/// are explicit WIP stubs so the layout matches the design doc.
struct MainWindow: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab = .chats

    enum Tab: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case models = "Models"
        case settings = "Settings"
        case logs = "Logs"

        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatsTab()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chats)

            ModelsTab()
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag(Tab.models)

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)

            LogsTab()
                .tabItem { Label("Logs", systemImage: "doc.text") }
                .tag(Tab.logs)
        }
        .padding()
    }
}

// MARK: - Tabs

private struct ChatsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chats").font(.title)
            Text("WIP — conversation list and message thread land in the next milestone.")
                .foregroundStyle(.secondary)
            if let conv = appState.currentConversation {
                Text("Active conversation id: \(conv.id.uuidString.prefix(8))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Button("Start a conversation (⌘N)") {
                    appState.startNewConversation()
                }
            }
            Spacer()
        }
    }
}

private struct ModelsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(.title)
            if appState.models.isEmpty {
                Text("No models installed yet. Run `mox pull <id>` from the CLI for now.")
                    .foregroundStyle(.secondary)
            } else {
                List(appState.models, id: \.id) { model in
                    HStack {
                        Text(model.name)
                        Spacer()
                        Text(model.source.rawValue).foregroundStyle(.secondary)
                        Text(model.sizeDescription).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }
}

private struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title)
                Form {
                    Section("运行模式") {
                        Picker("Mode", selection: $appState.daemonEnabled) {
                            Text("daemon 模式 (推荐)").tag(true)
                            Text("临时模式 (CLI)").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .disabled(appState.isModeChangeInFlight)
                        .onChange(of: appState.daemonEnabled) { _, newValue in
                            Task { await appState.applyModeChange(enabled: newValue) }
                        }

                        HStack(spacing: 8) {
                            Text("状态:")
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusLabel)
                                .font(.callout)
                        }
                    }

                    Section("Server") {
                        TextField("Host", text: $appState.serverHost)
                            .onChange(of: appState.serverHost) { _, _ in
                                appState.applyServerChange()
                            }
                        TextField(
                            "Port",
                            value: $appState.serverPort,
                            format: .number
                        )
                        .onChange(of: appState.serverPort) { _, _ in
                            appState.applyServerChange()
                        }
                    }

                    Section("Defaults") {
                        Stepper(value: $appState.maxTokens, in: 64...8192) {
                            Text("Max tokens: \(appState.maxTokens)")
                        }
                        .onChange(of: appState.maxTokens) { _, _ in
                            appState.applyDefaultsChange()
                        }
                        VStack(alignment: .leading) {
                            Text("Temperature: \(appState.temperature, specifier: "%.2f")")
                            Slider(value: $appState.temperature, in: 0...2)
                        }
                        .onChange(of: appState.temperature) { _, _ in
                            appState.applyDefaultsChange()
                        }
                    }

                    Section("Persistence") {
                        Text("Conversation history is in-memory only for v0.3. SQLite-backed persistence arrives in v0.5.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private var statusColor: Color {
        switch appState.mode {
        case .undetected: return .gray
        case .daemon: return .green
        case .temporary: return .orange
        }
    }

    private var statusLabel: String {
        switch appState.mode {
        case .undetected: return "Detecting…"
        case .daemon: return "Connected to \(appState.serverHost):\(appState.serverPort)"
        case .temporary: return "Temporary mode (CLI subprocess)"
        }
    }
}

private struct LogsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logs").font(.title)
            Text("WIP — log filter + tail view of `~/Library/Logs/Mox/` arrive next milestone.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
