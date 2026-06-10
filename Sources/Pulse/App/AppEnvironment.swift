import AppKit
import Foundation

/// Composition root: owns every long-lived object and wires them together.
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let store: UsageStore
    let history: HistoryStore
    let providers: [any UsageProvider]
    let scheduler: RefreshScheduler

    init() {
        let settings = SettingsStore()
        let store = UsageStore()
        let history = HistoryStore()
        let providers = ProviderFactory.makeAll()

        self.settings = settings
        self.store = store
        self.history = history
        self.providers = providers
        self.scheduler = RefreshScheduler(
            providers: providers,
            store: store,
            history: history,
            settings: settings
        )
    }

    func descriptor(for id: ProviderID) -> ProviderDescriptor {
        providers.first(where: { $0.id == id })!.descriptor
    }

    /// Opens the provider's desktop app when installed, else its web dashboard.
    func openProvider(_ id: ProviderID) {
        let descriptor = descriptor(for: id)
        if let bundleID = descriptor.appBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else {
            NSWorkspace.shared.open(descriptor.webURL)
        }
    }
}
