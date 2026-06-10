import AppKit
import SwiftUI

/// AppKit side of the click-through trick: the hosting view never wins hit
/// testing, so the status bar button receives every click while SwiftUI
/// renders the rich full-color label above it.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let panelController: PanelController
    private let settingsController: SettingsWindowController

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settingsController = SettingsWindowController(environment: environment)
        self.panelController = PanelController(environment: environment)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        panelController.openSettings = { [weak self] in self?.showSettings() }

        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        let descriptors = Dictionary(
            uniqueKeysWithValues: environment.providers.map { ($0.id, $0.descriptor) }
        )
        let label = StatusBarLabelView(
            store: environment.store,
            settings: environment.settings,
            descriptors: descriptors,
            onWidthChange: { [weak self] width in self?.updateLength(width) }
        )
        let hostingView = ClickThroughHostingView(rootView: label)
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
        ])
        updateLength(hostingView.fittingSize.width)

        button.target = self
        button.action = #selector(didClickStatusItem)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Byte Pulse — AI usage"
    }

    /// The status button derives its width from its own cell (empty here), so
    /// the item length must track the hosted label's measured width.
    private func updateLength(_ width: CGFloat) {
        guard width > 0 else { return }
        let length = width.rounded(.up)
        if abs(statusItem.length - length) > 0.5 {
            statusItem.length = length
        }
    }

    /// Debug hook (`--show-panel` launch argument) so the panel can be opened
    /// without a click, e.g. for screenshot verification.
    func showPanelForDebug() {
        guard let button = statusItem.button else { return }
        panelController.show(relativeTo: button)
    }

    /// `--dump-status` writes status-item geometry + view state to /tmp for
    /// verification runs.
    func dumpStatusForDebug() {
        let button = statusItem.button
        let selected = environment.settings.selectedTab
        let record = environment.store.record(for: selected)
        let histogramKeys = record.snapshot?.histograms.keys.map(\.rawValue).sorted() ?? []
        let lines = [
            "length=\(statusItem.length)",
            "buttonFrame=\(button?.frame ?? .zero)",
            "windowFrame=\(button?.window?.frame ?? .zero)",
            "dailyTimeframe=\(environment.settings.dailyTimeframe.rawValue)",
            "selectedTab=\(selected.rawValue)",
            "histograms[\(selected.rawValue)]=\(histogramKeys.joined(separator: ","))",
            "dailyBuckets=\(record.snapshot?.dailyUsage.count ?? -1)",
        ]
        try? lines.joined(separator: "\n").write(
            toFile: "/tmp/pulse-status.txt", atomically: true, encoding: .utf8
        )
    }

    @objc private func didClickStatusItem() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggle(relativeTo: button)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pulse", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        // Assigning a menu makes the next click show it; detach right after so
        // left-clicks keep toggling the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        environment.scheduler.refreshAll()
    }

    @objc private func openSettingsItem() {
        showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSettings() {
        settingsController.show()
    }
}
