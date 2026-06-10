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
}

/// One bar of the "Daily Usage" chart.
struct DailyUsage: Sendable, Equatable, Identifiable {
    /// Start of day in the local calendar.
    var date: Date
    var totals: TokenTotals

    var id: Date { date }
}
