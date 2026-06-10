import Foundation

/// Timeframes of the usage histogram card. Providers publish only the frames
/// their data source can honestly answer (e.g. Codex sessions carry day
/// granularity only → no `.day` hourly view).
enum UsageTimeframe: String, CaseIterable, Codable, Sendable {
    case day, week, month, year

    /// Badge label, cycling order = `allCases` order.
    var label: String {
        switch self {
        case .day: "1d"
        case .week: "7d"
        case .month: "30d"
        case .year: "1y"
        }
    }

    /// Calendar granularity of one bar.
    var bucket: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }
}

/// Everything a provider knows about its current usage, in one immutable value.
/// The UI renders whatever is present and hides what is `nil`/empty, so providers
/// with different capabilities (e.g. Gemini has quotas but no token costs) share
/// one shape.
struct UsageSnapshot: Sendable, Equatable {
    let providerID: ProviderID
    let fetchedAt: Date

    /// Plan label, e.g. "Max 5×", "Plus", "Pro", "Free tier".
    var plan: String?
    /// Short account hint shown in Settings (e.g. masked email).
    var accountLabel: String?

    /// The session-style gauge (Claude/Codex 5h, Cursor monthly plan, ...).
    var primary: LimitWindow?
    /// The weekly-style gauge.
    var secondary: LimitWindow?
    /// Additional gauges rendered as compact rows (per-model weekly caps,
    /// on-demand spend, Gemini per-model quotas, ...).
    var extraWindows: [LimitWindow] = []

    var tokens: TokenUsageReport?
    /// Ascending by date; the last 7 days (kept as the canonical activity signal).
    var dailyUsage: [DailyUsage] = []
    /// Usage histograms per supported timeframe (`.week` mirrors `dailyUsage`).
    var histograms: [UsageTimeframe: [DailyUsage]] = [:]

    /// Small caveats surfaced in the footer, e.g. "Limits from last session (12m old)".
    var statusNotes: [String] = []

    /// True when the limits source failed but the snapshot is still useful
    /// (e.g. token history parsed fine). The store then carries the previous
    /// snapshot's gauges forward instead of blanking the most important cards
    /// over a one-tick network blip.
    var limitsUnavailable = false

    init(providerID: ProviderID, fetchedAt: Date = .now) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
    }
}
