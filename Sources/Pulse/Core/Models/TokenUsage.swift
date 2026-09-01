import Foundation

/// Token counters plus optional cost for a period (a day, a month, ...).
struct TokenTotals: Sendable, Equatable, Codable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    /// Computed cost in USD. `nil` means "no cost data", not zero.
    var costUSD: Double?

    static let zero = TokenTotals()

    var total: Int64 { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 && costUSD == nil }

    /// Sums counters; cost is summed when at least one side carries it
    /// (so partially priced data still produces a useful estimate).
    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        switch (costUSD, other.costUSD) {
        case (nil, nil): break
        case let (lhs, rhs): costUSD = (lhs ?? 0) + (rhs ?? 0)
        }
    }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        var result = lhs
        result.add(rhs)
        return result
    }
}

/// Share of one model in a period's usage, for the breakdown rows.
struct ModelShare: Sendable, Equatable, Identifiable {
    /// Normalized display name, e.g. "opus-4.8".
    var model: String
    /// 0...100, share of the period's total tokens.
    var share: Double
    var totals: TokenTotals

    var id: String { model }
}

/// The "Token Usage" card content.
struct TokenUsageReport: Sendable, Equatable {
    var today: TokenTotals
    var thisMonth: TokenTotals
    /// Sorted descending by share; computed over the current month.
    var modelBreakdown: [ModelShare]
    /// Whether the Cost column should render (false for plan-included usage like Codex).
    var showsCost: Bool
    /// The slice of `today` produced by sub-agent (child) sessions. Always a
    /// **subset** of `today`, never an addition to it: a sub-agent's tokens are
    /// already counted in the headline row, so a card that added the two would
    /// double-count. Zero for sources that can't distinguish sub-agents
    /// (Claude Code never records a sub-agent's turns at all).
    var todaySubAgent: TokenTotals = .zero
    /// The slice of `thisMonth` produced by sub-agent sessions. Same subset rule.
    var thisMonthSubAgent: TokenTotals = .zero

    /// True when any sub-agent usage was observed in either window — the gate
    /// for showing the sub-agent rows at all.
    var hasSubAgentUsage: Bool { Self.isSubAgentSliceVisible(todaySubAgent) || Self.isSubAgentSliceVisible(thisMonthSubAgent) }

    /// Whether one window's sub-agent slice is worth a row of its own.
    ///
    /// An all-zero slice is not "a sub-agent that used nothing", it is **no
    /// sub-agent**: pi records no session parentage at all and Claude Code
    /// never logs a sub-agent's turns, so a row of zeros there states a fact
    /// about the harness the reader will misread as a fact about their usage.
    /// Cost is checked alongside the counters so a priced-but-tokenless slice
    /// (impossible today, cheap to be right about) still shows.
    static func isSubAgentSliceVisible(_ slice: TokenTotals) -> Bool {
        slice.total > 0 || (slice.costUSD ?? 0) > 0
    }
}

/// One bar of the "Daily Usage" chart.
struct DailyUsage: Sendable, Equatable, Identifiable {
    /// Start of day in the local calendar.
    var date: Date
    var totals: TokenTotals

    var id: Date { date }
}
