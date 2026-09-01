import Foundation

/// On-demand, read-only analytics for the breakdown window. It is a deliberate
/// sibling to `UsageStore` (the live dashboard): the breakdown is heavy,
/// lazily-computed detail the menu-bar panel never needs, so it lives off the
/// refresh hot path and is queried only while the window is open.
///
/// The service holds the *same* provider instances the scheduler drives, so a
/// query reuses the warm aggregation cache the live `fetch()` already filled —
/// no second parse of the log trees.
actor ProjectUsageService {
    private let providers: [ProviderID: any ProjectBreakdownProviding]

    /// Breakdown-capable providers in canonical display order. Fixed at init,
    /// so callers (e.g. the window's provider picker) can read it without
    /// awaiting the actor.
    nonisolated let supportedProviderIDs: [ProviderID]

    /// Designated init over the breakdown-capable providers directly. The live
    /// app passes the providers it already owns; demo/screenshot mode and tests
    /// pass lightweight stand-ins.
    init(breakdownProviders: [any ProjectBreakdownProviding]) {
        var capable: [ProviderID: any ProjectBreakdownProviding] = [:]
        for provider in breakdownProviders {
            capable[provider.id] = provider
        }
        self.providers = capable
        self.supportedProviderIDs = ProviderID.allCases.filter { capable[$0] != nil }
    }

    /// Filters the live provider set to those that can attribute usage by project.
    init(providers: [any UsageProvider]) {
        self.init(breakdownProviders: providers.compactMap { $0 as? any ProjectBreakdownProviding })
    }

    /// The breakdown for one provider over `timeframe`. Returns `nil` for
    /// providers without the capability and for those with no attributable
    /// usage in the window (the window then shows an empty state).
    func breakdown(
        for id: ProviderID,
        timeframe: BreakdownTimeframe,
        sources: UsageSourceSelection = .all,
        now: Date = .now
    ) async -> ProjectBreakdown? {
        guard let provider = providers[id] else { return nil }
        return await provider.projectBreakdown(timeframe: timeframe, sources: sources, now: now)
    }
}
