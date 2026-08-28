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
    /// On-demand per-project/session analytics for the breakdown window. Shares
    /// the provider instances (and their warm caches) with the scheduler.
    let projectUsage: ProjectUsageService
    /// True when launched with `--demo-data`: the breakdown shows Byte-branded
    /// mock data instead of the user's logs (for screenshots and demos).
    let isDemoData = ProcessInfo.processInfo.arguments.contains("--demo-data")

    init() {
        // Account discovery MUST run before SettingsStore is constructed.
        // SettingsStore reads ProviderID.allCases in its initialiser to decide
        // which persisted ids are still valid, so an empty registry at that
        // moment silently discards every discovered account and rewrites
        // UserDefaults without them.
        ProviderRegistry.shared.register(claudeAccounts: ClaudeAccount.discover().map(\.id))

        let settings = SettingsStore()
        let store = UsageStore()
        let history = HistoryStore()
        let providers = ProviderFactory.makeAll(captureTitles: settings.useSessionTitles)

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
        self.projectUsage = isDemoData
            ? ProjectUsageService(breakdownProviders: DemoBreakdownProvider.all)
            : ProjectUsageService(providers: providers)
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
