import Foundation

/// Incremental parser for `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Token semantics (verified in docs/RESEARCH/codex.md §3): `token_count`
/// events carry `info.total_token_usage` which is CUMULATIVE and non-decreasing
/// within one session file, so per-event deltas are computed against the
/// previous event and attributed to the model from the most recent
/// `turn_context`. OpenAI counts cached tokens as a subset of `input_tokens`
/// and reasoning as part of `output_tokens`, so display input = input − cached.
struct CodexSessionParser: Sendable {
    /// Per-file aggregate persisted by `FileAggregationCache`.
    struct FileAggregate: Codable, Sendable {
        /// "yyyy-MM-dd" derived from the session file's path date.
        var dayKey: String
        /// Per-model token deltas summed over the file.
        var models: [String: Tokens]
        /// Newest rate-limit snapshot in the file (limit_id == "codex").
        var rateLimits: RateLimitSnapshot?

        struct Tokens: Codable, Sendable {
            var input: Int64 = 0
            var cached: Int64 = 0
            var output: Int64 = 0
        }
    }

    struct RateLimitSnapshot: Codable, Sendable, Equatable {
        var date: Date
        var primaryUsedPercent: Double?
        var primaryWindowMinutes: Double?
        var primaryResetsAtEpoch: Double?
        var secondaryUsedPercent: Double?
        var secondaryWindowMinutes: Double?
        var secondaryResetsAtEpoch: Double?
    }

    let sessionsRoot: URL
    private let cache: FileAggregationCache<FileAggregate>

    init(
        sessionsRoot: URL = AppPaths.home.appendingPathComponent(".codex/sessions"),
        cacheName: String = "codex-files"
    ) {
        self.sessionsRoot = sessionsRoot
        self.cache = FileAggregationCache(name: cacheName)
    }

    // MARK: - Public surface

    struct Report: Sendable {
        var tokens: TokenUsageReport?
        var dailyUsage: [DailyUsage]
        var newestRateLimits: RateLimitSnapshot?
        /// Session files carry day granularity only → no `.day` (hourly) frame.
        var histograms: [UsageTimeframe: [DailyUsage]] = [:]
    }

    func report(now: Date = .now) async -> Report {
        let calendar = Calendar.current
        // A year of sessions feeds the 1y histogram; per-file caching makes
        // the wide window a one-time cost.
        let since = now.addingTimeInterval(-366 * 24 * 3600)

        let files = FileSnapshot.enumerate(root: sessionsRoot, pathExtension: "jsonl", modifiedSince: since)
        guard !files.isEmpty else {
            return Report(tokens: nil, dailyUsage: [], newestRateLimits: nil)
        }

        let aggregates = await cache.aggregates(for: files) { try Self.aggregate(file: $0) }
        return Self.merge(aggregates, calendar: calendar, now: now)
    }

    // MARK: - Per-file parse

    static func aggregate(file url: URL) throws -> FileAggregate {
        var models: [String: FileAggregate.Tokens] = [:]
        var currentModel = "gpt-5"
        var previous = TotalTokenUsage()
        var newestLimits: RateLimitSnapshot?

        try JSONLines.forEachLine(of: url) { line in
            // Cheap prefilter keeps conversation content out of the decoder.
            let isTokenCount = line.contains("token_count")
            let isTurnContext = line.contains("turn_context")
            guard isTokenCount || isTurnContext else { return }
            guard let event = JSONLines.decode(SessionLine.self, from: line) else { return }

            if isTurnContext, let model = event.payload?.model, !model.isEmpty {
                currentModel = model
            }

            guard isTokenCount else { return }

            if let totals = event.payload?.info?.totalTokenUsage {
                var delta = FileAggregate.Tokens()
                delta.input = max(0, (totals.inputTokens ?? 0) - (previous.inputTokens ?? 0))
                delta.cached = max(0, (totals.cachedInputTokens ?? 0) - (previous.cachedInputTokens ?? 0))
                delta.output = max(0, (totals.outputTokens ?? 0) - (previous.outputTokens ?? 0))
                previous = totals

                if delta.input > 0 || delta.cached > 0 || delta.output > 0 {
                    var bucket = models[currentModel] ?? .init()
                    bucket.input += delta.input
                    bucket.cached += delta.cached
                    bucket.output += delta.output
                    models[currentModel] = bucket
                }
            }

            if let limits = event.payload?.rateLimits,
               limits.limitID == nil || limits.limitID == "codex",
               limits.primary != nil {
                let date = event.timestamp.flatMap(Self.parseISO) ?? .now
                if newestLimits == nil || date >= newestLimits!.date {
                    newestLimits = RateLimitSnapshot(
                        date: date,
                        primaryUsedPercent: limits.primary?.usedPercent,
                        primaryWindowMinutes: limits.primary?.windowMinutes,
                        primaryResetsAtEpoch: limits.primary?.resetsAt,
                        secondaryUsedPercent: limits.secondary?.usedPercent,
                        secondaryWindowMinutes: limits.secondary?.windowMinutes,
                        secondaryResetsAtEpoch: limits.secondary?.resetsAt
                    )
                }
            }
        }

        return FileAggregate(
            dayKey: dayKey(forSessionFile: url),
            models: models,
            rateLimits: newestLimits
        )
    }

    /// The sessions tree is `YYYY/MM/DD/rollout-*.jsonl`; the directory date is
    /// the session's local day.
    static func dayKey(forSessionFile url: URL) -> String {
        let parts = url.pathComponents
        if parts.count >= 4 {
            let candidates = parts.suffix(4).prefix(3)
            if candidates.count == 3,
               let year = Int(candidates[candidates.startIndex]),
               (2000...2200).contains(year) {
                let month = candidates[candidates.index(after: candidates.startIndex)]
                let day = candidates[candidates.index(candidates.startIndex, offsetBy: 2)]
                return String(format: "%04d-%@-%@", year, month, day)
            }
        }
        return "unknown"
    }

    // MARK: - Merge

    static func merge(_ aggregates: [FileAggregate], calendar: Calendar, now: Date) -> Report {
        let formatter = dayFormatter(calendar: calendar)
        let todayKey = formatter.string(from: now)
        let monthPrefix = String(todayKey.prefix(7))

        var today = TokenTotals()
        var month = TokenTotals()
        var perModelMonth: [String: TokenTotals] = [:]
        var perDay: [Date: TokenTotals] = [:]
        var newestLimits: RateLimitSnapshot?

        for aggregate in aggregates {
            if let limits = aggregate.rateLimits {
                if newestLimits == nil || limits.date > newestLimits!.date {
                    newestLimits = limits
                }
            }

            let fileTotals = aggregate.models.values.reduce(into: TokenTotals()) { running, tokens in
                running.add(Self.displayTotals(tokens))
            }

            if aggregate.dayKey == todayKey { today.add(fileTotals) }
            if aggregate.dayKey.hasPrefix(monthPrefix) {
                month.add(fileTotals)
                for (model, tokens) in aggregate.models {
                    perModelMonth[model, default: .zero].add(Self.displayTotals(tokens))
                }
            }
            if let date = formatter.date(from: aggregate.dayKey) {
                perDay[calendar.startOfDay(for: date), default: .zero].add(fileTotals)
            }
        }

        let monthTotal = max(month.total, 1)
        let breakdown = perModelMonth
            .map { model, totals in
                ModelShare(
                    model: ModelNames.display(model),
                    share: Double(totals.total) / Double(monthTotal) * 100,
                    totals: totals
                )
            }
            .sorted { $0.share > $1.share }

        let tokens: TokenUsageReport? = month.total > 0 || today.total > 0
            ? TokenUsageReport(today: today, thisMonth: month, modelBreakdown: breakdown, showsCost: false)
            : nil

        let week = UsageMath.lastSevenDays(from: perDay, calendar: calendar, now: now)
        return Report(
            tokens: tokens,
            dailyUsage: week,
            newestRateLimits: newestLimits,
            histograms: [
                .week: week,
                .month: UsageMath.lastDays(30, from: perDay, calendar: calendar, now: now),
                .year: UsageMath.lastMonths(12, from: perDay, calendar: calendar, now: now),
            ]
        )
    }

    /// Display mapping: cached prompt tokens are a subset of `input_tokens`,
    /// so the Input column shows the uncached remainder; Codex usage is plan-
    /// included, so cost stays nil.
    static func displayTotals(_ tokens: FileAggregate.Tokens) -> TokenTotals {
        TokenTotals(
            input: max(0, tokens.input - tokens.cached),
            output: tokens.output,
            cacheRead: tokens.cached,
            cacheWrite: 0,
            costUSD: nil
        )
    }

    static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func parseISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}

// MARK: - Targeted line decode (usage fields only, never message content)

struct TotalTokenUsage: Codable, Sendable {
    var inputTokens: Int64?
    var cachedInputTokens: Int64?
    var outputTokens: Int64?
    var reasoningOutputTokens: Int64?
    var totalTokens: Int64?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct SessionLine: Decodable {
    var timestamp: String?
    var type: String?
    var payload: Payload?

    struct Payload: Decodable {
        var type: String?
        var model: String?
        var info: Info?
        var rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type, model, info
            case rateLimits = "rate_limits"
        }
    }

    struct Info: Decodable {
        var totalTokenUsage: TotalTokenUsage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
        }
    }

    struct RateLimits: Decodable {
        var limitID: String?
        var primary: Window?
        var secondary: Window?

        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary, secondary
        }

        struct Window: Decodable {
            var usedPercent: Double?
            var windowMinutes: Double?
            var resetsAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }
    }
}
