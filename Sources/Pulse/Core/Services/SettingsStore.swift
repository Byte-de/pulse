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

    /// How the panel arranges enabled providers.
    enum PanelLayout: String, CaseIterable, Sendable {
        /// One provider at a time behind a segmented tab bar.
        case tabs
        /// Every enabled provider side by side, one column each, no tab bar.
        case columns

        var title: String {
            switch self {
            case .tabs: "One at a time (tabs)"
            case .columns: "All side by side"
            }
        }
    }

    /// How much of the panel is drawn.
    ///
    /// Two modes rather than a pile of per-card switches: the full view answers
    /// "where did my usage go", the simple view answers "can I keep working",
    /// and those want different amounts of screen. Toggled from the bottom bar
    /// (⌘E) so the answer to the second question is never more than one glance
    /// away, and the first is never more than one click away.
    enum PanelMode: String, CaseIterable, Sendable {
        /// Every card the provider publishes: rates, histograms, tokens, disk,
        /// processes. What the panel has always shown.
        case full
        /// One ring per provider for the live session window, its weekly bar
        /// underneath, and CPU + memory for the machine. Nothing else.
        case simple

        var title: String {
            switch self {
            case .full: "Everything"
            case .simple: "Just the essentials"
            }
        }
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
        static let countProviderLogs = "countProviderLogs"
        static let countJcodeSessions = "countJcodeSessions"
        static let countPiSessions = "countPiSessions"
        static let breakdownSources = "breakdownSources"
        static let gaugeDirection = "gaugeDirection"
        static let showPaceMarker = "showPaceMarker"
        static let panelLayout = "panelLayout"
        static let panelMode = "panelMode"
        static let showSystemStats = "showSystemStats"
        static let showSystemProcesses = "showSystemProcesses"
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

    /// Whether the panel stacks providers behind tabs or shows every enabled
    /// provider as its own column. Columns widen the panel by one column per
    /// provider, so the controller derives the window width from this.
    var panelLayout: PanelLayout {
        didSet { defaults.set(panelLayout.rawValue, forKey: Key.panelLayout) }
    }

    /// Whether the panel draws every card or only the glance view. Orthogonal
    /// to `panelLayout`: the simple view always puts providers side by side,
    /// because with two or three cards that short there is nothing to gain from
    /// hiding all but one behind a tab bar.
    var panelMode: PanelMode {
        didSet { defaults.set(panelMode.rawValue, forKey: Key.panelMode) }
    }

    /// Whether the panel carries the machine-stats sidebar on its left. It is
    /// the only part of the panel that is not about a provider account, so it
    /// is separately switchable: a user who never runs agents locally has no
    /// use for it and pays a column of width for it.
    var showSystemStats: Bool {
        didSet { defaults.set(showSystemStats, forKey: Key.showSystemStats) }
    }

    /// Whether the sidebar lists the top CPU processes. Separate from the
    /// sidebar switch because this is the one part that spawns `ps` on every
    /// tick and shows process names, so it can be turned off on its own.
    var showSystemProcesses: Bool {
        didSet { defaults.set(showSystemProcesses, forKey: Key.showSystemProcesses) }
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

    /// Source filter of the breakdown window **only**. Deliberately separate
    /// from the three `count*` switches: the panel answers "what am I
    /// spending", and the breakdown answers "what did this tool cost me on this
    /// project", which needs a source turned off for one question without
    /// changing the answer to the other.
    var breakdownSources: UsageSourceSelection {
        didSet { defaults.set(breakdownSources.storedValue, forKey: Key.breakdownSources) }
    }

    /// Whether the breakdown may show CLI-generated session titles (Claude's
    /// `ai-title`). When false, Pulse stays strictly content-blind: title
    /// records are never even decoded. Default on (the user opted into titles).
    var useSessionTitles: Bool {
        didSet { defaults.set(useSessionTitles, forKey: Key.useSessionTitles) }
    }

    // MARK: - Which session logs count

    /// Count the provider CLI's own logs (`~/.claude/projects`, `~/.codex/sessions`).
    var countProviderLogs: Bool {
        didSet {
            defaults.set(countProviderLogs, forKey: Key.countProviderLogs)
            publishUsageSources()
        }
    }

    /// Count jcode's sessions (`~/.jcode/sessions`), which bill the same accounts.
    var countJcodeSessions: Bool {
        didSet {
            defaults.set(countJcodeSessions, forKey: Key.countJcodeSessions)
            publishUsageSources()
        }
    }

    /// Count pi's sessions (`~/.pi/agent/sessions`), which bill the same accounts.
    var countPiSessions: Bool {
        didSet {
            defaults.set(countPiSessions, forKey: Key.countPiSessions)
            publishUsageSources()
        }
    }

    /// The three switches as the provider actors read them. Pushed on every
    /// change (and once at init) rather than pulled, because Core must not
    /// depend on this `@MainActor` type.
    private func publishUsageSources() {
        UsageSourceGate.shared.current = UsageSourceSelection(
            providerLogs: countProviderLogs,
            jcode: countJcodeSessions,
            pi: countPiSessions
        )
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

        gaugeDirection = defaults.string(forKey: Key.gaugeDirection)
            .flatMap(GaugeDirection.init(rawValue:)) ?? .remaining

        // Default on: the tick is the only thing that turns a percentage into
        // "am I ahead or behind". `object(forKey:)` rather than `bool(forKey:)`
        // because the latter returns false for an absent key, which would
        // silently ship the feature disabled.
        showPaceMarker = (defaults.object(forKey: Key.showPaceMarker) as? Bool) ?? true

        // Default columns: with two or three providers enabled, one click
        // showing all of them beats three clicks showing one each.
        panelLayout = defaults.string(forKey: Key.panelLayout)
            .flatMap(PanelLayout.init(rawValue:)) ?? .columns

        // Default full: an existing user's panel must not silently lose cards
        // on upgrade, and a new user has to see what the app can do before
        // being offered the short version of it.
        panelMode = defaults.string(forKey: Key.panelMode)
            .flatMap(PanelMode.init(rawValue:)) ?? .full

        // Default on: the sidebar is the reason the panel is useful while an
        // agent is running locally, and it is invisible unless the panel is open.
        showSystemStats = (defaults.object(forKey: Key.showSystemStats) as? Bool) ?? true
        showSystemProcesses = (defaults.object(forKey: Key.showSystemProcesses) as? Bool) ?? true

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
        // Absent key (never touched) means every source, not none.
        breakdownSources = UsageSourceSelection(stored: defaults.stringArray(forKey: Key.breakdownSources))
        // Default on: the user opted into CLI-generated titles in the design phase.
        useSessionTitles = (defaults.object(forKey: Key.useSessionTitles) as? Bool) ?? true

        // All three default on: the totals before these switches existed
        // counted every source, so any other default would silently change a
        // returning user's numbers on upgrade.
        countProviderLogs = (defaults.object(forKey: Key.countProviderLogs) as? Bool) ?? true
        countJcodeSessions = (defaults.object(forKey: Key.countJcodeSessions) as? Bool) ?? true
        countPiSessions = (defaults.object(forKey: Key.countPiSessions) as? Bool) ?? true

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

        // Providers read the gate on their first refresh, which can begin
        // before any view touches Settings, so it is seeded here rather than
        // by the first `didSet`.
        publishUsageSources()
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
