import AppKit
import SwiftUI

/// Menu-bar status item, registered only when the GUI launches in daemon mode.
/// v0.3 ships a stub: a button labelled "Mox" that opens a small popover with
/// the current model name and an "Open Mox" affordance. Quick-prompt input
/// (the killer feature for a status-bar utility) lands alongside the
/// conversation UI in the next milestone.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var popover: NSPopover?

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
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
            popover.contentSize = NSSize(width: 220, height: 80)
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

/// Minimal popover content. The real implementation grows alongside the
/// conversation UI.
private struct StatusBarPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mox").font(.headline)
            Text("Status: running (daemon mode)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open Mox") {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
