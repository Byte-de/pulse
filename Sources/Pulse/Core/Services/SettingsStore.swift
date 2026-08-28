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
        static let breakdownProvider = "breakdownProvider"
        static let breakdownTimeframe = "breakdownTimeframe"
        static let breakdownSort = "breakdownSort"
        static let useSessionTitles = "useSessionTitles"
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

    // MARK: - Breakdown window

    /// Last provider selected in the breakdown window.
    var breakdownProvider: ProviderID {
        didSet { defaults.set(breakdownProvider.rawValue, forKey: Key.breakdownProvider) }
    }

    /// Last timeframe selected in the breakdown window.
    var breakdownTimeframe: BreakdownTimeframe {
        didSet { defaults.set(breakdownTimeframe.rawValue, forKey: Key.breakdownTimeframe) }
    }

    /// Last project sort selected in the breakdown window.
    var breakdownSort: BreakdownSort {
        didSet { defaults.set(breakdownSort.rawValue, forKey: Key.breakdownSort) }
    }

    /// Whether the breakdown may show CLI-generated session titles (Claude's
    /// `ai-title`). When false, Pulse stays strictly content-blind: title
    /// records are never even decoded. Default on (the user opted into titles).
    var useSessionTitles: Bool {
        didSet { defaults.set(useSessionTitles, forKey: Key.useSessionTitles) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = storedInterval >= 30 ? storedInterval : 60

        // A ProviderID is now a struct, so `init(rawValue:)` never fails and
        // `compactMap` no longer filters anything. Unknown ids must be
        // rejected explicitly against the live registry, or a provider that
        // was removed (or an account whose directory is gone) is resurrected
        // from UserDefaults on every launch.
        let known = Set(ProviderID.allCases)
        if let raw = defaults.stringArray(forKey: Key.enabledProviders) {
            let ids = Set(raw.map(ProviderID.init(rawValue:)).filter(known.contains))
            enabledProviders = ProviderID.allCases.filter(ids.contains)
        } else {
            enabledProviders = ProviderID.allCases
        }

        if let raw = defaults.stringArray(forKey: Key.menuBarProviders) {
            menuBarProviders = Set(raw.map(ProviderID.init(rawValue:)).filter(known.contains))
        } else {
            menuBarProviders = Set(ProviderID.allCases)
        }

        menuBarStyle = defaults.string(forKey: Key.menuBarStyle)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .stats

        selectedTab = defaults.string(forKey: Key.selectedTab)
            .flatMap(ProviderID.init(rawValue:)) ?? .claude

        dailyTimeframe = defaults.string(forKey: Key.dailyTimeframe)
            .flatMap(UsageTimeframe.init(rawValue:)) ?? .week

        breakdownProvider = defaults.string(forKey: Key.breakdownProvider)
            .flatMap(ProviderID.init(rawValue:)) ?? .claude
        breakdownTimeframe = defaults.string(forKey: Key.breakdownTimeframe)
            .flatMap(BreakdownTimeframe.init(rawValue:)) ?? .last30Days
        breakdownSort = defaults.string(forKey: Key.breakdownSort)
            .flatMap(BreakdownSort.init(rawValue:)) ?? .tokens
        // Default on: the user opted into CLI-generated titles in the design phase.
        useSessionTitles = (defaults.object(forKey: Key.useSessionTitles) as? Bool) ?? true

        // Providers introduced by an app update default to enabled+visible even
        // when older persisted selections predate them (e.g. Copilot arriving
        // after the user already toggled providers).
        //
        // Discovered Claude accounts are the exception and default to **off**.
        // A shipped provider arriving is our decision and the user can see why;
        // an account appearing because a directory showed up in their home
        // folder is not, and silently claiming menu bar width for it is a
        // surprise. They opt in from Settings > Claude Accounts.
        let previouslyKnown = Set(
            (defaults.stringArray(forKey: Key.knownProviders) ?? [])
                .map(ProviderID.init(rawValue:))
        )
        if !previouslyKnown.isEmpty {
            let introduced = ProviderID.allCases.filter { !previouslyKnown.contains($0) }
            let autoEnabled = introduced.filter { !$0.isClaudeAccount || $0 == .claude }
            if !autoEnabled.isEmpty {
                let enabled = Set(enabledProviders).union(autoEnabled)
                enabledProviders = ProviderID.allCases.filter(enabled.contains)
                menuBarProviders.formUnion(autoEnabled)
            }
        }
        defaults.set(ProviderID.allCases.map(\.rawValue), forKey: Key.knownProviders)
        // Ids no longer in the registry are dropped above on read, but nothing
        // rewrites the stored array, so a stale id would survive every launch
        // and reappear the moment its directory did.
        defaults.set(enabledProviders.map(\.rawValue), forKey: Key.enabledProviders)
        defaults.set(menuBarProviders.map(\.rawValue).sorted(), forKey: Key.menuBarProviders)
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
