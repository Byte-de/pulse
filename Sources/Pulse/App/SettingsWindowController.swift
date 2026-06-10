import AppKit
import SwiftUI

/// Plain NSWindow + NSHostingController; cached and reused. Accessory apps
/// must activate before presenting, or the window opens behind others.
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(
            rootView: SettingsView(environment: environment)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Pulse Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 480))
        window.center()
        return window
    }
}
