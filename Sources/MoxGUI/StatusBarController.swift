import AppKit
import SwiftUI

/// Menu-bar status item, registered only when the GUI launches in daemon
/// mode. The popover shows a model label and an "Open Mox" affordance.
/// Quick-prompt input lands alongside the conversation UI in a later
/// milestone.
@MainActor
final class StatusBarController {
    private nonisolated(unsafe) let statusItem: NSStatusItem
    private var popover: NSPopover?
    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
    }

    /// Remove the status item from the system bar. Without this the menu-bar
    /// icon stays orphaned when the controller is dropped on mode toggle,
    /// so a daemon→temporary→daemon round trip leaves two ghost "Mox"
    /// items.
    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Make the status item visible. Idempotent — calling twice is harmless.
    func activate(currentModel: String?) {
        if let button = statusItem.button {
            let title = currentModel.map { "Mox — \($0)" } ?? "Mox"
            button.title = title
        }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 240, height: 120)
            popover.contentViewController = NSHostingController(
                rootView: StatusBarPopover()
            )
            self.popover = popover
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.title = "Mox"
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

private struct StatusBarPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mox").font(.headline)
            Text("Status: running (daemon mode)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open Mox") {
                NSApp.activate()
                // Reveal the main window if the user closed it; `WindowGroup`
                // does not auto-restore on macOS 14+.
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}