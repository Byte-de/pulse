import AppKit
import SwiftUI

/// Resizable NSWindow hosting the per-project/session breakdown. Same lifecycle
/// as `SettingsWindowController` (cached, accessory-app activation), but resizable
/// — it's a data table the user keeps open beside their work, not a transient
/// popover. Owns the view model so selection + expansion survive close/reopen.
@MainActor
final class BreakdownWindowController {
    private let environment: AppEnvironment
    private let model: BreakdownViewModel
    private var window: NSWindow?
    private var refreshTask: Task<Void, Never>?

    /// Live-refresh cadence while the window is on screen — frequent enough to
    /// keep the "Active now" badge honest, cheap because the cache stays warm.
    private let autoRefreshSeconds: TimeInterval = 20

    init(environment: AppEnvironment) {
        self.environment = environment
        self.model = BreakdownViewModel(environment: environment)
    }

    deinit { refreshTask?.cancel() }

    /// Opens (or re-focuses) the window. When `initialProvider` is a
    /// breakdown-capable provider, it becomes the selected tab — so opening from
    /// the panel lands on the tab the user was just viewing.
    func show(initialProvider: ProviderID? = nil) {
        let wasOpen = window != nil
        let previousProvider = model.selectedProvider
        if let initialProvider, model.supportedProviders.contains(initialProvider) {
            model.selectedProvider = initialProvider
        }
        // The selection is persisted and the window is cached, so a provider
        // disabled since the last open would otherwise stay selected with no
        // tab to switch away from.
        if !model.supportedProviders.contains(model.selectedProvider),
           let fallback = model.supportedProviders.first {
            model.selectedProvider = fallback
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startAutoRefresh()
        // Reopening a cached window doesn't re-fire the view's first-appear load,
        // so refresh explicitly — but only when the selection is unchanged, since
        // a provider switch already reloads via the view's `.task(id:)`.
        if wasOpen, model.selectedProvider == previousProvider {
            Task { await model.load() }
        }
    }

    /// A single visibility-gated loop, created on first show and living for the
    /// app's lifetime. It only reads the log tree while the window is actually on
    /// screen — an ordered-out (closed), minimized, or fully-occluded window
    /// triggers no work.
    private func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.autoRefreshSeconds ?? 20
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                if let window = self.window, window.isVisible, window.occlusionState.contains(.visible) {
                    await self.model.load()
                }
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: BreakdownView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Usage Breakdown"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 880, height: 600))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("PulseBreakdownWindow")
        window.center()

        // Screenshot/verification hooks: pin a fixed appearance (matches the
        // panel's --force-light/--force-dark behavior) so demo captures are
        // deterministic regardless of the system setting.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--force-dark") {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("--force-light") {
            window.appearance = NSAppearance(named: .aqua)
        }
        return window
    }
}
