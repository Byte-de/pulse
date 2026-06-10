import Foundation

// MARK: - Flexible JSON scalars

/// Cursor's dashboard endpoints disagree on scalar encodings: token counts are
/// strings in `get-aggregated-usage-events` but ints in
/// `get-filtered-usage-events`; epoch-ms values arrive as strings or numbers
/// (docs/RESEARCH/cursor.md §6.3). These wrappers accept either representation.
struct StringOrInt64: Decodable, Sendable, Equatable {
    var value: Int64

    init(_ value: Int64) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int64(double)
        } else if let string = try? container.decode(String.self),
                  let parsed = Self.parse(string) {
            value = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an integer or a numeric string"
            )
        }
    }

    private static func parse(_ string: String) -> Int64? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let int = Int64(trimmed) { return int }
        if let double = Double(trimmed) { return Int64(double) }
        return nil
    }
}

/// See `StringOrInt64` — same idea for fractional values (cents, dollars).
struct StringOrDouble: Decodable, Sendable, Equatable {
    var value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self),
                  let parsed = Double(string.trimmingCharacters(in: .whitespaces)) {
            value = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a number or a numeric string"
            )
        }
    }
}

// MARK: - Dates

enum CursorDates {
    /// ISO-8601 with or without fractional seconds ("2026-06-07T11:52:11.948Z").
    static func iso(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func fromEpochMS(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

// MARK: - GET /api/usage (legacy request gauge)

/// `{"gpt-4": {numRequests, maxRequestUsage (null on free)}, startOfMonth}`.
struct CursorLegacyUsage: Decodable, Sendable {
    struct ModelGauge: Decodable, Sendable {
        var numRequests: Int?
        var numRequestsTotal: Int?
        var maxRequestUsage: Int?
    }

    var gpt4: ModelGauge?
    /// Quota-period start (reset anchor), ISO-8601.
    var startOfMonth: String?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
        case startOfMonth
    }
}

// MARK: - GET /api/usage-summary (modern plan summary)

/// Cents-valued plan summary; percent fields are already in percent units.
/// Decoded fully tolerantly — every field optional.
struct CursorUsageSummary: Decodable, Sendable {
    struct PlanUsage: Decodable, Sendable {
        var enabled: Bool?
        var used: StringOrDouble?
        var limit: StringOrDouble?
        var autoPercentUsed: StringOrDouble?
        var apiPercentUsed: StringOrDouble?
        var totalPercentUsed: StringOrDouble?
    }

    struct OnDemandUsage: Decodable, Sendable {
        var enabled: Bool?
        var used: StringOrDouble?
        var limit: StringOrDouble?
    }

    struct IndividualUsage: Decodable, Sendable {
        var plan: PlanUsage?
        var onDemand: OnDemandUsage?
    }

    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var individualUsage: IndividualUsage?

    /// Headline plan utilization, precedence per docs/RESEARCH/oss-reference.md
    /// §A3: server percent → avg of lanes → single lane → cents ratio.
    var planPercentUsed: Double? {
        guard let plan = individualUsage?.plan else { return nil }
        if let total = plan.totalPercentUsed?.value {
            return max(0, total)
        }
        let auto = plan.autoPercentUsed?.value
        let api = plan.apiPercentUsed?.value
        if let auto, let api {
            return max(0, (auto + api) / 2)
        }
        if let lane = auto ?? api {
            return max(0, lane)
        }
        if let used = plan.used?.value, let limit = plan.limit?.value, limit > 0 {
            return max(0, used / limit * 100)
        }
        return nil
    }
}

// MARK: - POST /api/dashboard/get-hard-limit

/// `{"hardLimit": 125}` — usage-based spending cap in dollars.
struct CursorHardLimit: Decodable, Sendable {
    var hardLimit: StringOrDouble?
}

// MARK: - POST /api/dashboard/get-monthly-invoice

/// Billing-period bounds (string epoch-ms, calendar month) plus usage line
/// items (cents) on accounts with billed overage. Items are best-effort —
/// absent when all usage was plan-included.
struct CursorMonthlyInvoice: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var cents: StringOrDouble?
        var description: String?
    }

    var periodStartMs: StringOrInt64?
    var periodEndMs: StringOrInt64?
    var items: [Item]?

    var periodStart: Date? { periodStartMs.map { CursorDates.fromEpochMS($0.value) } }
    var periodEnd: Date? { periodEndMs.map { CursorDates.fromEpochMS($0.value) } }

    /// Sum of positive line-item cents; nil when the invoice carries no items
    /// (credits/mid-month payments appear as negative cents and are excluded).
    var usageItemCentsTotal: Double? {
        guard let items, !items.isEmpty else { return nil }
        return items.compactMap { $0.cents?.value }.filter { $0 > 0 }.reduce(0, +)
    }
}

// MARK: - POST /api/dashboard/get-aggregated-usage-events

/// Per-model month totals. Token counts are STRINGS here, `totalCents` is a
/// number. An empty month returns `{}` (no `aggregations` key at all).
struct CursorAggregatedUsage: Decodable, Sendable {
    struct Aggregation: Decodable, Sendable {
        var modelIntent: String?
        var inputTokens: StringOrInt64?
        var outputTokens: StringOrInt64?
        var cacheWriteTokens: StringOrInt64?
        var cacheReadTokens: StringOrInt64?
        var totalCents: StringOrDouble?
    }

    var aggregations: [Aggregation]?
    var totalCostCents: StringOrDouble?
}

// MARK: - POST /api/dashboard/get-filtered-usage-events

/// Per-event log, newest first. `timestamp` is epoch-ms (string or number);
/// token counts inside `tokenUsage` are INTS here (strings tolerated anyway).
struct CursorFilteredEvents: Decodable, Sendable {
    struct TokenUsage: Decodable, Sendable {
        var inputTokens: StringOrInt64?
        var outputTokens: StringOrInt64?
        var cacheWriteTokens: StringOrInt64?
        var cacheReadTokens: StringOrInt64?
        var totalCents: StringOrDouble?
    }

    struct Event: Decodable, Sendable {
        var timestamp: StringOrInt64?
        var model: String?
        var tokenUsage: TokenUsage?
        var chargedCents: StringOrDouble?

        var date: Date? { timestamp.map { CursorDates.fromEpochMS($0.value) } }
    }

    var usageEventsDisplay: [Event]?
    var totalUsageEventsCount: Int?
}
