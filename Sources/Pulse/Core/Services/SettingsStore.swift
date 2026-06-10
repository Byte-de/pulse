import Foundation
import Observation
import ServiceManagement

/// User preferences, UserDefaults-backed and observable by the UI.
@MainActor
@Observable
final class SettingsStore {
    enum MenuBarStyle: String, CaseIterable {
        /// Per-provider colored stat blocks (the reference design).
        case stats
        /// Just the app glyph.
        case icon
    }

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let enabledProviders = "enabledProviders"
        static let menuBarProviders = "menuBarProviders"
        static let menuBarStyle = "menuBarStyle"
        static let selectedTab = "selectedTab"
        static let dailyTimeframe = "dailyTimeframe"
        static let knownProviders = "knownProviders"
    }

    private let defaults: UserDefaults

    /// Seconds between provider refreshes. 30…600.
    var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// Providers shown as tabs, in canonical order.
    var enabledProviders: [ProviderID] {
        didSet { defaults.set(enabledProviders.map(\.rawValue), forKey: Key.enabledProviders) }
    }

    /// Subset of enabled providers rendered in the menu bar label.
    var menuBarProviders: Set<ProviderID> {
        didSet { defaults.set(menuBarProviders.map(\.rawValue).sorted(), forKey: Key.menuBarProviders) }
    }

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Last selected provider tab, restored when the panel reopens.
    var selectedTab: ProviderID {
        didSet { defaults.set(selectedTab.rawValue, forKey: Key.selectedTab) }
    }

    /// Timeframe of the usage histogram card (the clickable "7d" badge).
    var dailyTimeframe: UsageTimeframe {
        didSet { defaults.set(dailyTimeframe.rawValue, forKey: Key.dailyTimeframe) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = storedInterval >= 30 ? storedInterval : 60

        if let raw = defaults.stringArray(forKey: Key.enabledProviders) {
            let ids = raw.compactMap(ProviderID.init(rawValue:))
            enabledProviders = ProviderID.allCases.filter(ids.contains)
        } else {
            enabledProviders = ProviderID.allCases
        }

        if let raw = defaults.stringArray(forKey: Key.menuBarProviders) {
            menuBarProviders = Set(raw.compactMap(ProviderID.init(rawValue:)))
        } else {
            menuBarProviders = Set(ProviderID.allCases)
        }

        menuBarStyle = defaults.string(forKey: Key.menuBarStyle)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .stats

        selectedTab = defaults.string(forKey: Key.selectedTab)
            .flatMap(ProviderID.init(rawValue:)) ?? .claude

        dailyTimeframe = defaults.string(forKey: Key.dailyTimeframe)
            .flatMap(UsageTimeframe.init(rawValue:)) ?? .week

        // Providers introduced by an app update default to enabled+visible even
        // when older persisted selections predate them (e.g. Copilot arriving
        // after the user already toggled providers).
        let known = Set(
            (defaults.stringArray(forKey: Key.knownProviders) ?? [])
                .compactMap(ProviderID.init(rawValue:))
        )
        if !known.isEmpty {
            let introduced = ProviderID.allCases.filter { !known.contains($0) }
            if !introduced.isEmpty {
                let enabled = Set(enabledProviders).union(introduced)
                enabledProviders = ProviderID.allCases.filter(enabled.contains)
                menuBarProviders.formUnion(introduced)
                defaults.set(enabledProviders.map(\.rawValue), forKey: Key.enabledProviders)
                defaults.set(menuBarProviders.map(\.rawValue).sorted(), forKey: Key.menuBarProviders)
            }
        }
        defaults.set(ProviderID.allCases.map(\.rawValue), forKey: Key.knownProviders)
    }

    /// Providers actually shown in the bar: enabled ∩ menuBarProviders, canonical order.
    var visibleMenuBarProviders: [ProviderID] {
        enabledProviders.filter(menuBarProviders.contains)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Pulse: launch-at-login change failed: \(error.localizedDescription)")
            }
        }
    }
}
