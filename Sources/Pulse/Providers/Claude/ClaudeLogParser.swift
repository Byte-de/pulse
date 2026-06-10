import Foundation

/// Incremental parser for `~/.claude/projects/**/*.jsonl` (hundreds of files,
/// ~hundreds of MB). Per-file work is cached by (size, mtime); the global
/// dedup + rollup runs in-memory on the cached entries each refresh.
///
/// Parsing rules (verified, docs/RESEARCH/claude.md §3):
/// - only `type:"assistant"` records carry `.message.usage`; skip `<synthetic>`
/// - the same logical message is written multiple times (streamed partials),
///   so entries dedup globally on `message.id|requestId` keeping the MAX
///   `output_tokens` (first-wins undercounts)
/// - `costUSD` is always null in current Claude Code → cost is computed from
///   the pricing table, with the 5m/1h cache-write split when present.
struct ClaudeLogParser: Sendable {
    /// One usage line, compact for the on-disk cache.
    struct Entry: Codable, Sendable, Equatable {
        /// "messageID|requestId" — nil when either id is missing (never deduped).
        var key: String?
        /// Local-day "yyyy-MM-dd".
        var day: String
        var model: String
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite5m: Int64
        var cacheWrite1h: Int64
        /// Local hour 0–23, for the 1-day histogram. Optional so caches written
        /// before this field existed still decode (their entries simply don't
        /// contribute to hourly buckets until their file is re-parsed).
        var hour: Int?

        /// Streamed partials precede finals with the same key; the collapse
        /// keeps whichever record reports the most output tokens.
        var outputForDedup: Int64 { output }
    }

    let projectsRoot: URL
    private let cache: FileAggregationCache<[Entry]>

    init(
        projectsRoot: URL = AppPaths.home.appendingPathComponent(".claude/projects"),
        cacheName: String = "claude-files"
    ) {
        self.projectsRoot = projectsRoot
        self.cache = FileAggregationCache(name: cacheName)
    }

    func report(now: Date = .now) async -> TokenReportBundle {
        let calendar = Calendar.current
        // A year of files feeds the 1y histogram; the per-file cache makes the
        // wide window a one-time cost (only changed files re-parse afterwards).
        let since = now.addingTimeInterval(-366 * 24 * 3600)

        let files = FileSnapshot.enumerate(root: projectsRoot, pathExtension: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return TokenReportBundle(tokens: nil, dailyUsage: []) }

        let entryLists = await cache.aggregates(for: files) { try Self.parseFile($0) }
        return Self.rollUp(entryLists, calendar: calendar, now: now)
    }

    // MARK: - Per-file parse

    /// Parses one JSONL file into compact entries. Keyed duplicates inside the
    /// file (streamed partials, up to ~3.75× per message) are pre-collapsed to
    /// the max-output record so the on-disk cache stays small; the global
    /// cross-file dedup in `rollUp` applies the same rule again.
    /// Throws on unreadable files so the aggregation cache retries them.
    static func parseFile(_ url: URL) throws -> [Entry] {
        var keyed: [String: Entry] = [:]
        var keyless: [Entry] = []
        let formatter = localDayFormatter()
        let iso = ClaudeISO8601()
        try JSONLines.forEachLine(of: url) { line in
            guard line.contains("\"assistant\""), line.contains("\"usage\"") else { return }
            guard let entry = parseLine(line, dayFormatter: formatter, iso: iso) else { return }
            if let key = entry.key {
                if let existing = keyed[key], existing.outputForDedup >= entry.outputForDedup { return }
                keyed[key] = entry
            } else {
                keyless.append(entry)
            }
        }
        return keyless + keyed.values
    }

    static func parseLine(_ line: Substring, dayFormatter: DateFormatter) -> Entry? {
        parseLine(line, dayFormatter: dayFormatter, iso: ClaudeISO8601())
    }

    static func parseLine(_ line: Substring, dayFormatter: DateFormatter, iso: ClaudeISO8601) -> Entry? {
        guard let record = JSONLines.decode(LogLine.self, from: line),
              record.type == "assistant",
              let message = record.message,
              let usage = message.usage,
              let model = message.model,
              model != "<synthetic>"
        else { return nil }

        let day: String
        let hour: Int
        if let timestamp = record.timestamp, let date = iso.date(from: timestamp) {
            day = dayFormatter.string(from: date)
            hour = Calendar.current.component(.hour, from: date)
        } else {
            return nil
        }

        // The breakdown object, when present, is authoritative for the 5m/1h
        // split; without it all cache_creation_input_tokens bill at the 5m rate.
        let write5m: Int64
        let write1h: Int64
        if let breakdown = usage.cacheCreation {
            write5m = breakdown.ephemeral5m ?? 0
            write1h = breakdown.ephemeral1h ?? 0
        } else {
            write5m = usage.cacheCreationInputTokens ?? 0
            write1h = 0
        }

        return Entry(
            key: zip2(message.id, record.requestId).map { "\($0)|\($1)" },
            day: day,
            model: model,
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            hour: hour
        )
    }

    // MARK: - Global dedup + rollups

    static func rollUp(_ entryLists: [[Entry]], calendar: Calendar, now: Date) -> TokenReportBundle {
        // Global dedup across all files: keyed entries collapse to the
        // max-output record (streamed partials precede finals); keyless
        // entries are all kept.
        var best: [String: Entry] = [:]
        var keyless: [Entry] = []
        for entry in entryLists.joined() {
            if let key = entry.key {
                if let existing = best[key], existing.outputForDedup >= entry.outputForDedup { continue }
                best[key] = entry
            } else {
                keyless.append(entry)
            }
        }

        let formatter = localDayFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let todayKey = formatter.string(from: now)
        let monthPrefix = String(todayKey.prefix(7))

        var today = TokenTotals()
        var month = TokenTotals()
        var perModelMonth: [String: TokenTotals] = [:]
        var perDay: [Date: TokenTotals] = [:]
        var perHourToday: [Date: TokenTotals] = [:]
        let todayStart = calendar.startOfDay(for: now)

        func accumulate(_ entry: Entry) {
            let totals = totals(of: entry)
            if entry.day == todayKey {
                today.add(totals)
                if let hour = entry.hour,
                   let bucket = calendar.date(byAdding: .hour, value: hour, to: todayStart) {
                    perHourToday[bucket, default: .zero].add(totals)
                }
            }
            if entry.day.hasPrefix(monthPrefix) {
                month.add(totals)
                // Bucket by display name so dated aliases of the same model
                // ("claude-haiku-4-5-20251001") merge into one row.
                perModelMonth[ModelNames.display(entry.model), default: .zero].add(totals)
            }
            if let date = formatter.date(from: entry.day) {
                perDay[calendar.startOfDay(for: date), default: .zero].add(totals)
            }
        }
        for entry in best.values { accumulate(entry) }
        for entry in keyless { accumulate(entry) }

        guard month.total > 0 || today.total > 0 || !perDay.isEmpty else {
            return TokenReportBundle(tokens: nil, dailyUsage: [])
        }

        let monthTotal = Double(max(month.total, 1))
        var breakdown: [ModelShare] = perModelMonth.map { model, totals in
            ModelShare(model: model, share: Double(totals.total) / monthTotal * 100, totals: totals)
        }
        breakdown.sort { lhs, rhs in
            if lhs.share == rhs.share { return lhs.model < rhs.model }
            return lhs.share > rhs.share
        }

        let week = UsageMath.lastSevenDays(from: perDay, calendar: calendar, now: now)
        return TokenReportBundle(
            tokens: TokenUsageReport(today: today, thisMonth: month, modelBreakdown: breakdown, showsCost: true),
            dailyUsage: week,
            histograms: [
                .day: UsageMath.hoursOfToday(from: perHourToday, calendar: calendar, now: now),
                .week: week,
                .month: UsageMath.lastDays(30, from: perDay, calendar: calendar, now: now),
                .year: UsageMath.lastMonths(12, from: perDay, calendar: calendar, now: now),
            ]
        )
    }

    static func totals(of entry: Entry) -> TokenTotals {
        TokenTotals(
            input: entry.input,
            output: entry.output,
            cacheRead: entry.cacheRead,
            cacheWrite: entry.cacheWrite5m + entry.cacheWrite1h,
            costUSD: PricingTable.cost(
                model: entry.model,
                input: entry.input,
                output: entry.output,
                cacheRead: entry.cacheRead,
                cacheWrite5m: entry.cacheWrite5m,
                cacheWrite1h: entry.cacheWrite1h
            )
        )
    }

    // MARK: - Helpers

    /// "yyyy-MM-dd" in the user's timezone (tests may override `timeZone`).
    static func localDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

struct TokenReportBundle: Sendable {
    var tokens: TokenUsageReport?
    var dailyUsage: [DailyUsage]
    /// Per-timeframe histograms; absent frames are unsupported by the source.
    var histograms: [UsageTimeframe: [DailyUsage]] = [:]
}

// MARK: - Targeted line decode

private struct LogLine: Decodable {
    var type: String?
    var timestamp: String?
    var requestId: String?
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    struct Usage: Decodable {
        var inputTokens: Int64?
        var outputTokens: Int64?
        var cacheReadInputTokens: Int64?
        var cacheCreationInputTokens: Int64?
        var cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }
    }

    struct CacheCreation: Decodable {
        var ephemeral5m: Int64?
        var ephemeral1h: Int64?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens"
            case ephemeral1h = "ephemeral_1h_input_tokens"
        }
    }
}
