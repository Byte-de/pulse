import Foundation
import Observation

/// Drives the breakdown window: holds the current provider/timeframe/sort
/// selection, loads breakdowns on demand from `ProjectUsageService`, and
/// (Phase 4) keeps the view fresh while the window is open. Owned by the window
/// controller so selection + expansion survive close/reopen of the cached window.
@MainActor
@Observable
final class BreakdownViewModel {
    private let environment: AppEnvironment

    var selectedProvider: ProviderID
    var timeframe: BreakdownTimeframe
    var sort: BreakdownSort
    /// Which writers this window counts. Local to the window: changing it never
    /// touches the panel's own switches (Settings > Count Tokens From).
    var sources: UsageSourceSelection
    /// Project ids whose sessions are expanded in the outline.
    var expandedProjects: Set<String> = []

    private(set) var breakdown: ProjectBreakdown?
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    /// Demo/screenshot mode expands the top project once so the drill-down shows.
    private var didApplyDemoExpansion = false

    /// Breakdown-capable providers the user actually enabled, in canonical
    /// order. Capability alone is not enough: every discovered Claude account
    /// can produce a breakdown, so filtering only on that shows tabs for
    /// accounts the user deliberately switched off in Settings.
    ///
    /// Computed rather than stored because the view model outlives the window:
    /// it is built once at launch, so a stored list would keep showing a tab
    /// for a provider disabled since.
    var supportedProviders: [ProviderID] {
        let enabled = Set(environment.settings.enabledProviders)
        return environment.projectUsage.supportedProviderIDs.filter(enabled.contains)
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        let enabled = Set(environment.settings.enabledProviders)
        let supported = environment.projectUsage.supportedProviderIDs.filter(enabled.contains)
        let preferred = environment.settings.breakdownProvider
        self.selectedProvider = supported.contains(preferred) ? preferred : (supported.first ?? .claude)
        self.timeframe = environment.settings.breakdownTimeframe
        self.sort = environment.settings.breakdownSort
        self.sources = environment.settings.breakdownSources
    }

    /// Sources that can actually contribute to the selected provider. Only
    /// Claude accounts have harnesses billing them; Codex has one writer, its
    /// own CLI, so offering it a jcode switch would be a control that provably
    /// does nothing.
    var applicableSources: [UsageSourceSelection.Source] {
        selectedProvider.isClaudeAccount ? UsageSourceSelection.Source.allCases : [.providerLogs]
    }

    /// Whether the source filter is worth showing at all for this provider.
    var showsSourceFilter: Bool { applicableSources.count > 1 }

    func descriptor(for id: ProviderID) -> ProviderDescriptor { environment.descriptor(for: id) }

    /// Key that changes whenever a reload is required (provider/timeframe).
    /// Sort changes only reorder in memory, so they're intentionally excluded.
    var reloadKey: String {
        "\(selectedProvider.rawValue)|\(timeframe.rawValue)|\(sources.storedValue.joined(separator: ","))"
    }

    /// Projects ordered by the active sort.
    var sortedProjects: [ProjectUsage] { sort.sorted(breakdown?.projects ?? []) }

    var showsCost: Bool { breakdown?.showsCost ?? (selectedProvider == .claude) }

    /// Message for the empty state, distinguishing "not signed in" from
    /// "signed in but nothing in this window" from "you filtered it all out" —
    /// the third would otherwise read as missing data.
    var emptyMessage: String {
        let name = descriptor(for: selectedProvider).name
        if sources.enabled.isEmpty {
            return "Every source is switched off in the Sources filter."
        }
        if case .notConnected = environment.store.record(for: selectedProvider).displayState {
            return "\(name) isn't connected yet."
        }
        if sources != .all {
            return "No \(name) usage from \(sources.summary) in the last \(timeframe.label)."
        }
        return "No \(name) usage in the last \(timeframe.label)."
    }

    /// Loads the breakdown for the current selection. Safe to call repeatedly;
    /// the `.task(id:)` driving it cancels superseded loads automatically.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        var result = await environment.projectUsage.breakdown(
            for: selectedProvider,
            timeframe: timeframe,
            sources: sources
        )
        // Honor the content-blind setting immediately in the UI; a relaunch then
        // stops the parser reading titles into the cache at all.
        if let loaded = result, !environment.settings.useSessionTitles {
            result = loaded.hidingSessionTitles()
        }
        guard !Task.isCancelled else { return }
        breakdown = result
        lastLoaded = .now

        // Demo/screenshot mode: expand the top project once so the screenshot
        // shows the project → session drill-down (never affects real usage).
        if environment.isDemoData, !didApplyDemoExpansion, let top = sortedProjects.first {
            expandedProjects.insert(top.id)
            didApplyDemoExpansion = true
        }
    }

    func toggleExpanded(_ projectID: String) {
        if expandedProjects.contains(projectID) {
            expandedProjects.remove(projectID)
        } else {
            expandedProjects.insert(projectID)
        }
    }

    func isExpanded(_ projectID: String) -> Bool { expandedProjects.contains(projectID) }

    /// Persists the current view preferences (called when they change).
    func persistPreferences() {
        environment.settings.breakdownTimeframe = timeframe
        environment.settings.breakdownSort = sort
        environment.settings.breakdownProvider = selectedProvider
        environment.settings.breakdownSources = sources
    }
}
