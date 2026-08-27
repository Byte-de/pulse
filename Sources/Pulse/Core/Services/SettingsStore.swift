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

    /// Which direction a limit gauge reads.
    enum GaugeDirection: String, CaseIterable, Sendable {
        /// Consumption: bar fills left to right as usage climbs, percentage is
        /// the amount used (0 -> 100). The conventional progress-bar reading.
        case used
        /// Remaining: bar drains right to left, percentage is what is left
        /// (100 -> 0). Reads as a fuel gauge, and lines up with the on-pace
        /// tick, which also marks time *remaining*.
        case remaining

        var title: String {
            switch self {
            case .used: "Used (0 to 100%)"
            case .remaining: "Remaining (100 to 0%)"
            }
        }

        /// The number to display for a raw utilization.
        func displayValue(utilization: Double) -> Double {
            switch self {
            case .used: utilization
            case .remaining: max(0, 100 - utilization)
            }
        }

        /// Fraction of the bar to fill, 0...1.
        func fillFraction(utilization: Double) -> Double {
            let used = min(max(utilization / 100, 0), 1)
            return self == .used ? used : 1 - used
        }

        /// Where the on-pace tick sits, 0...1, given the elapsed fraction of
        /// the window. It tracks the fill so the two are comparable: under
        /// `.used` both grow rightward, under `.remaining` both drain leftward.
        func markerPosition(elapsedFraction: Double) -> Double {
            let elapsed = min(max(elapsedFraction, 0), 1)
            return self == .used ? elapsed : 1 - elapsed
        }
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
        static let gaugeDirection = "gaugeDirection"
        static let showPaceMarker = "showPaceMarker"
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

    /// Whether limit gauges show what is used or what is left. Applies to the
    /// bar, the headline percentage and the pace tick together: a bar and a
    /// number that disagreed about direction would be worse than either
    /// convention on its own.
    var gaugeDirection: GaugeDirection {
        didSet { defaults.set(gaugeDirection.rawValue, forKey: Key.gaugeDirection) }
    }

    /// Whether limit gauges draw the on-pace tick: the mark showing where the
    /// window clock sits, so the bar can be read against elapsed time rather
    /// than in isolation. Off gives a plain bar, and the row shrinks by the
    /// marker's overhang rather than leaving a gap where it was.
    var showPaceMarker: Bool {
        didSet { defaults.set(showPaceMarker, forKey: Key.showPaceMarker) }
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

        gaugeDirection = defaults.string(forKey: Key.gaugeDirection)
            .flatMap(GaugeDirection.init(rawValue:)) ?? .remaining

        // Default on: the tick is the only thing that turns a percentage into
        // "am I ahead or behind". `object(forKey:)` rather than `bool(forKey:)`
        // because the latter returns false for an absent key, which would
        // silently ship the feature disabled.
        showPaceMarker = (defaults.object(forKey: Key.showPaceMarker) as? Bool) ?? true

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
