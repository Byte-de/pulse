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
    /// Per-file aggregate persisted by `FileAggregationCache` (1 file = 1 session).
    struct FileAggregate: Codable, Sendable {
        /// "yyyy-MM-dd" derived from the session file's path date.
        var dayKey: String
        /// Per-model token deltas summed over the file.
        var models: [String: Tokens]
        /// Newest rate-limit snapshot in the file (limit_id == "codex").
        var rateLimits: RateLimitSnapshot?
        /// Working directory recorded in the session (project attribution for
        /// the breakdown; unused by the aggregate token card).
        var cwd: String?
        /// Session id (the rollout's `session_meta.id`, else the file UUID).
        var sessionID: String?
        /// Activity span, for breakdown sorting + the minute-accurate "Active
        /// now" signal (the day-granular `dayKey` is too coarse for liveness).
        var firstActivity: Date?
        var lastActivity: Date?

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
        cacheName: String = "codex-files-v2"
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
        var cwd: String?
        var sessionID: String?
        var firstActivity: Date?
        var lastActivity: Date?

        try JSONLines.forEachLine(of: url) { line in
            // Cheap prefilter keeps conversation content out of the decoder.
            let isTokenCount = line.contains("token_count")
            let isTurnContext = line.contains("turn_context")
            let isSessionMeta = line.contains("session_meta")
            guard isTokenCount || isTurnContext || isSessionMeta else { return }
            guard let event = JSONLines.decode(SessionLine.self, from: line) else { return }

            // Activity span across every decoded structural line.
            let date = event.timestamp.flatMap(Self.parseISO)
            if let date {
                if firstActivity == nil || date < firstActivity! { firstActivity = date }
                if lastActivity == nil || date > lastActivity! { lastActivity = date }
            }

            // Identity: session_meta is canonical (cwd + id, logged first);
            // turn_context's cwd is a fallback for sessions without meta.
            if let payloadCwd = event.payload?.cwd, !payloadCwd.isEmpty, cwd == nil { cwd = payloadCwd }
            if isSessionMeta, let id = event.payload?.id, !id.isEmpty { sessionID = id }

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
                let limitDate = date ?? .now
                if newestLimits == nil || limitDate >= newestLimits!.date {
                    newestLimits = RateLimitSnapshot(
                        date: limitDate,
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
            rateLimits: newestLimits,
            cwd: cwd,
            sessionID: sessionID ?? Self.sessionID(forSessionFile: url),
            firstActivity: firstActivity,
            lastActivity: lastActivity
        )
    }

    /// Extracts the session UUID from a `rollout-<timestamp>-<uuid>.jsonl`
    /// filename, falling back to the full stem when the shape is unexpected.
    static func sessionID(forSessionFile url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let range = stem.range(of: uuid, options: .regularExpression) {
            return String(stem[range])
        }
        return stem
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

            let fileTotals = aggregate.models.reduce(into: TokenTotals()) { running, entry in
                running.add(Self.displayTotals(entry.value, model: entry.key))
            }

            if aggregate.dayKey == todayKey { today.add(fileTotals) }
            if aggregate.dayKey.hasPrefix(monthPrefix) {
                month.add(fileTotals)
                for (model, tokens) in aggregate.models {
                    perModelMonth[model, default: .zero].add(Self.displayTotals(tokens, model: model))
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
            ? TokenUsageReport(today: today, thisMonth: month, modelBreakdown: breakdown, showsCost: true)
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

    // MARK: - Project / session breakdown

    /// Per-project/session usage over `timeframe`, reusing the warm cache the
    /// live `report()` fills. Codex aggregates per file at day granularity, so
    /// whole sessions are included/excluded by their `dayKey`.
    func breakdown(timeframe: BreakdownTimeframe, now: Date = .now) async -> [ProjectUsage] {
        let calendar = Calendar.current
        let since = now.addingTimeInterval(-366 * 24 * 3600)
        let files = FileSnapshot.enumerate(root: sessionsRoot, pathExtension: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return [] }
        let aggregates = await cache.aggregates(for: files) { try Self.aggregate(file: $0) }
        return Self.rollUpBreakdown(aggregates, timeframe: timeframe, calendar: calendar, now: now)
    }

    /// Groups cached sessions into projects by `cwd`. Empty or out-of-frame
    /// sessions are dropped; cost stays nil (Codex usage is plan-included).
    static func rollUpBreakdown(
        _ aggregates: [FileAggregate],
        timeframe: BreakdownTimeframe,
        calendar: Calendar,
        now: Date,
        liveThreshold: TimeInterval = 5 * 60
    ) -> [ProjectUsage] {
        let formatter = dayFormatter(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let cutoffDate = calendar.date(byAdding: .day, value: -(timeframe.days - 1), to: today) ?? today
        let cutoffDay = formatter.string(from: cutoffDate)

        var aggregator = ProjectUsageAggregator()
        for aggregate in aggregates where aggregate.dayKey >= cutoffDay {
            var totals = TokenTotals()
            var perModel: [String: TokenTotals] = [:]
            for (model, tokens) in aggregate.models {
                let display = displayTotals(tokens, model: model)
                totals.add(display)
                perModel[ModelNames.display(model), default: .zero].add(display)
            }
            guard totals.total > 0 else { continue }

            let lastActivity = aggregate.lastActivity ?? formatter.date(from: aggregate.dayKey) ?? now
            let key = aggregate.cwd ?? "unknown"
            let session = SessionUsage(
                id: aggregate.sessionID ?? "\(key)-\(aggregate.dayKey)",
                title: nil,
                gitBranch: nil,
                totals: totals,
                startedAt: aggregate.firstActivity,
                lastActivity: lastActivity,
                isActive: now.timeIntervalSince(lastActivity) < liveThreshold,
                modelBreakdown: UsageMath.modelShares(perModel)
            )
            aggregator.add(
                session,
                projectKey: key,
                displayPath: ProjectDisplay.displayPath(cwd: aggregate.cwd, fallback: "Unknown project"),
                name: ProjectDisplay.name(cwd: aggregate.cwd, fallback: "Unknown project")
            )
        }
        return aggregator.projects()
    }

    /// Display mapping: cached prompt tokens are a subset of `input_tokens`,
    /// so the Input column shows the uncached remainder.
    ///
    /// Cost is computed from the token counts against published per-model
    /// rates, exactly as the Claude parser does. Codex writes no cost into its
    /// logs, and a plan-included subscription still has a meterable value - the
    /// figure answers "what would this usage have cost on the API", which is
    /// the only cost question the logs can answer.
    ///
    /// Codex reports no cache-write counter, so `cacheWrite` is zero and the
    /// cached tokens bill at the cheaper read rate. That makes the estimate a
    /// floor rather than an exact reproduction of a bill.
    static func displayTotals(_ tokens: FileAggregate.Tokens, model: String? = nil) -> TokenTotals {
        let input = max(0, tokens.input - tokens.cached)
        return TokenTotals(
            input: input,
            output: tokens.output,
            cacheRead: tokens.cached,
            cacheWrite: 0,
            costUSD: model.flatMap {
                PricingTable.cost(
                    model: $0,
                    input: input,
                    output: tokens.output,
                    cacheRead: tokens.cached,
                    cacheWrite5m: 0,
                    cacheWrite1h: 0
                )
            }
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
        /// Present on `session_meta` (canonical) and `turn_context`.
        var id: String?
        var cwd: String?

        enum CodingKeys: String, CodingKey {
            case type, model, info, id, cwd
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
