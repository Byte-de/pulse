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

    /// One session file's cached aggregate (1 file = 1 session): the deduped
    /// usage entries plus the session's identity and activity span. `report()`
    /// flattens `entries` for the token card; `breakdown()` additionally groups
    /// by `projectKey` / `sessionID`. Stored verbatim by `FileAggregationCache`.
    struct SessionFile: Codable, Sendable, Equatable {
        /// Encoded project-directory name (parent dir) — the stable grouping key.
        var projectKey: String
        /// Working directory recorded in the session's lines (accurate display
        /// path); `nil` only for sessions that logged no usable `cwd`.
        var projectPath: String?
        /// Session id = the log file's stem (`<sessionId>.jsonl`).
        var sessionID: String
        /// Git branch at the session's latest activity, when logged.
        var gitBranch: String?
        /// CLI-generated session title (`ai-title`); `nil` in content-blind mode.
        var title: String?
        var firstActivity: Date?
        var lastActivity: Date?
        var entries: [Entry]
        /// True when the session was spawned by another session (jcode's
        /// `parent_id`). Optional so caches written before the field existed
        /// still decode; `nil` reads as "not a sub-agent". Claude Code never
        /// sets it — it does not record a sub-agent's turns at all
        /// (docs/HANDOFF-jcode-subagent-attribution.md, Appendix A).
        var isSubAgent: Bool?
    }

    let projectsRoot: URL
    /// When false (content-blind mode), `ai-title` records are never decoded,
    /// so no title text ever enters the on-disk cache or the UI.
    let captureTitles: Bool
    private let cache: FileAggregationCache<SessionFile>

    init(
        projectsRoot: URL = AppPaths.home.appendingPathComponent(".claude/projects"),
        captureTitles: Bool = true,
        cacheName: String? = nil
    ) {
        self.projectsRoot = projectsRoot
        self.captureTitles = captureTitles
        // Title capture changes what each aggregate stores, so the two modes use
        // separate cache files — flipping the setting can't surface stale titles.
        let defaultName = captureTitles ? "claude-files-v2" : "claude-files-v2-blind"
        self.cache = FileAggregationCache(name: cacheName ?? defaultName)
    }

    func report(now: Date = .now) async -> TokenReportBundle {
        let calendar = Calendar.current
        let sessions = await sessions(now: now)
        guard !sessions.isEmpty else { return TokenReportBundle(tokens: nil, dailyUsage: []) }
        return Self.rollUp(sessions: sessions, calendar: calendar, now: now)
    }

    /// The parsed session files themselves, so a caller can merge them with
    /// another harness's sessions for the same account (jcode) and roll the
    /// combined set up once.
    func sessions(now: Date = .now) async -> [SessionFile] {
        // A year of files feeds the 1y histogram; the per-file cache makes the
        // wide window a one-time cost (only changed files re-parse afterwards).
        let since = now.addingTimeInterval(-366 * 24 * 3600)
        let files = FileSnapshot.enumerate(root: projectsRoot, pathExtension: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return [] }
        return await cache.aggregates(for: files) { try Self.parseSession($0, captureTitles: captureTitles) }
    }

    // MARK: - Per-file parse

    /// Parses one session file into its cached aggregate: deduped usage entries
    /// plus the session's identity, git branch, optional title, and activity
    /// span. Keyed duplicates inside the file (streamed partials, up to ~3.75×
    /// per message) are pre-collapsed to the max-output record so the on-disk
    /// cache stays small; the global cross-file dedup in `rollUp` applies the
    /// same rule again. Throws on unreadable files so the cache retries them.
    static func parseSession(_ url: URL, captureTitles: Bool) throws -> SessionFile {
        var keyed: [String: Entry] = [:]
        var keyless: [Entry] = []
        var cwd: String?
        var gitBranch: String?
        var title: String?
        var firstActivity: Date?
        var lastActivity: Date?
        let formatter = localDayFormatter()
        let iso = ClaudeISO8601()
        try JSONLines.forEachLine(of: url) { line in
            // `ai-title` is a separate record type; decode it only when titles
            // are enabled, and confirm the type so a prompt that merely mentions
            // the string can't be mistaken for one. Last title wins.
            if captureTitles, line.contains("ai-title") {
                if let record = JSONLines.decode(TitleLine.self, from: line),
                   record.type == "ai-title",
                   let aiTitle = record.aiTitle, !aiTitle.isEmpty {
                    title = aiTitle
                }
                return
            }
            guard line.contains("\"assistant\""), line.contains("\"usage\"") else { return }
            guard let parsed = parseUsageLine(line, dayFormatter: formatter, iso: iso) else { return }

            // cwd is stable per session; git branch can change mid-session, so
            // the last-seen value reflects the session's current state.
            if let lineCwd = parsed.cwd, !lineCwd.isEmpty { cwd = lineCwd }
            if let branch = parsed.gitBranch, !branch.isEmpty { gitBranch = branch }
            if firstActivity == nil || parsed.date < firstActivity! { firstActivity = parsed.date }
            if lastActivity == nil || parsed.date > lastActivity! { lastActivity = parsed.date }

            let entry = parsed.entry
            if let key = entry.key {
                if let existing = keyed[key], existing.outputForDedup >= entry.outputForDedup { return }
                keyed[key] = entry
            } else {
                keyless.append(entry)
            }
        }
        return SessionFile(
            projectKey: projectKey(for: url),
            projectPath: cwd,
            sessionID: sessionID(for: url),
            gitBranch: gitBranch,
            title: title,
            firstActivity: firstActivity,
            lastActivity: lastActivity,
            entries: keyless + keyed.values
        )
    }

    /// The encoded project-directory name (parent of the session file) — a
    /// stable grouping key even when a session records no `cwd`.
    static func projectKey(for url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    /// The session id — the log file's stem (Claude names files `<sessionId>.jsonl`).
    static func sessionID(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func parseLine(_ line: Substring, dayFormatter: DateFormatter) -> Entry? {
        parseUsageLine(line, dayFormatter: dayFormatter, iso: ClaudeISO8601())?.entry
    }

    static func parseLine(_ line: Substring, dayFormatter: DateFormatter, iso: ClaudeISO8601) -> Entry? {
        parseUsageLine(line, dayFormatter: dayFormatter, iso: iso)?.entry
    }

    /// One assistant-usage line, decoded once into its usage `Entry` plus the
    /// session metadata the breakdown needs (cwd, git branch, exact timestamp).
    /// Returns `nil` for non-usage records and undated lines, exactly as the
    /// entry-only `parseLine` overloads do.
    struct ParsedUsageLine {
        var entry: Entry
        var date: Date
        var cwd: String?
        var gitBranch: String?
    }

    static func parseUsageLine(
        _ line: Substring,
        dayFormatter: DateFormatter,
        iso: ClaudeISO8601
    ) -> ParsedUsageLine? {
        guard let record = JSONLines.decode(LogLine.self, from: line),
              record.type == "assistant",
              let message = record.message,
              let usage = message.usage,
              let model = message.model,
              model != "<synthetic>"
        else { return nil }

        guard let timestamp = record.timestamp, let date = iso.date(from: timestamp) else { return nil }
        let day = dayFormatter.string(from: date)
        let hour = Calendar.current.component(.hour, from: date)

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

        let entry = Entry(
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
        return ParsedUsageLine(entry: entry, date: date, cwd: record.cwd, gitBranch: record.gitBranch)
    }

    // MARK: - Global dedup + rollups

    /// Rolls up whole sessions, so each entry keeps the sub-agent flag of the
    /// session it came from and the card can show the sub-agent slice.
    static func rollUp(sessions: [SessionFile], calendar: Calendar, now: Date) -> TokenReportBundle {
        rollUp(sessions.map { (entries: $0.entries, isSubAgent: $0.isSubAgent ?? false) }, calendar: calendar, now: now)
    }

    /// Entry-list form, used by callers that have no session context (their
    /// usage is main-session by definition).
    static func rollUp(_ entryLists: [[Entry]], calendar: Calendar, now: Date) -> TokenReportBundle {
        rollUp(entryLists.map { (entries: $0, isSubAgent: false) }, calendar: calendar, now: now)
    }

    static func rollUp(
        _ entryLists: [(entries: [Entry], isSubAgent: Bool)],
        calendar: Calendar,
        now: Date
    ) -> TokenReportBundle {
        // Global dedup across all files: keyed entries collapse to the
        // max-output record (streamed partials precede finals); keyless
        // entries are all kept.
        var best: [String: (entry: Entry, isSubAgent: Bool)] = [:]
        var keyless: [(entry: Entry, isSubAgent: Bool)] = []
        for list in entryLists {
            for entry in list.entries {
                if let key = entry.key {
                    if let existing = best[key], existing.entry.outputForDedup >= entry.outputForDedup { continue }
                    best[key] = (entry, list.isSubAgent)
                } else {
                    keyless.append((entry, list.isSubAgent))
                }
            }
        }

        let formatter = localDayFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let todayKey = formatter.string(from: now)
        let monthPrefix = String(todayKey.prefix(7))

        var today = TokenTotals()
        var month = TokenTotals()
        var todaySub = TokenTotals()
        var monthSub = TokenTotals()
        var perModelMonth: [String: TokenTotals] = [:]
        var perDay: [Date: TokenTotals] = [:]
        var perHourToday: [Date: TokenTotals] = [:]
        let todayStart = calendar.startOfDay(for: now)

        func accumulate(_ entry: Entry, isSubAgent: Bool) {
            let totals = totals(of: entry)
            if entry.day == todayKey {
                today.add(totals)
                if isSubAgent { todaySub.add(totals) }
                if let hour = entry.hour,
                   let bucket = calendar.date(byAdding: .hour, value: hour, to: todayStart) {
                    perHourToday[bucket, default: .zero].add(totals)
                }
            }
            if entry.day.hasPrefix(monthPrefix) {
                month.add(totals)
                if isSubAgent { monthSub.add(totals) }
                // Bucket by display name so dated aliases of the same model
                // ("claude-haiku-4-5-20251001") merge into one row.
                perModelMonth[ModelNames.display(entry.model), default: .zero].add(totals)
            }
            if let date = formatter.date(from: entry.day) {
                perDay[calendar.startOfDay(for: date), default: .zero].add(totals)
            }
        }
        for item in best.values { accumulate(item.entry, isSubAgent: item.isSubAgent) }
        for item in keyless { accumulate(item.entry, isSubAgent: item.isSubAgent) }

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
            tokens: TokenUsageReport(
                today: today,
                thisMonth: month,
                modelBreakdown: breakdown,
                showsCost: true,
                todaySubAgent: todaySub,
                thisMonthSubAgent: monthSub
            ),
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

    // MARK: - Project / session breakdown

    /// Per-project/session usage over `timeframe`, reusing the same warm cache
    /// `report()` fills. The file window is identical to `report()`'s, so the
    /// two callers share cache entries with no thrash and no extra parse.
    func breakdown(timeframe: BreakdownTimeframe, now: Date = .now) async -> [ProjectUsage] {
        let sessions = await sessions(now: now)
        guard !sessions.isEmpty else { return [] }
        return Self.rollUpBreakdown(sessions, timeframe: timeframe, calendar: Calendar.current, now: now)
    }

    /// Groups cached sessions into projects, filtering each session's entries to
    /// `timeframe`. Sessions (and projects) with no in-frame usage are dropped.
    /// Within-file dedup already happened in `parseSession`, so per-session sums
    /// are correct without the cross-file dedup the aggregate token card needs.
    static func rollUpBreakdown(
        _ sessions: [SessionFile],
        timeframe: BreakdownTimeframe,
        calendar: Calendar,
        now: Date,
        liveThreshold: TimeInterval = 5 * 60
    ) -> [ProjectUsage] {
        let formatter = localDayFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let cutoffDay = breakdownCutoffDay(timeframe, formatter: formatter, calendar: calendar, now: now)

        var aggregator = ProjectUsageAggregator()
        for session in sessions {
            let inFrame = session.entries.filter { $0.day >= cutoffDay }
            guard !inFrame.isEmpty else { continue }

            var totals = TokenTotals()
            var perModel: [String: TokenTotals] = [:]
            var latestDay = ""
            for entry in inFrame {
                let entryTotals = Self.totals(of: entry)
                totals.add(entryTotals)
                perModel[ModelNames.display(entry.model), default: .zero].add(entryTotals)
                if entry.day > latestDay { latestDay = entry.day }
            }

            // Prefer the exact captured timestamp; fall back to the in-frame day
            // only for entries from a pre-v2 cache that never stored one.
            let lastActivity = session.lastActivity ?? formatter.date(from: latestDay) ?? now

            let sessionUsage = SessionUsage(
                id: session.sessionID,
                title: session.title,
                gitBranch: session.gitBranch,
                totals: totals,
                startedAt: session.firstActivity,
                lastActivity: lastActivity,
                isActive: now.timeIntervalSince(lastActivity) < liveThreshold,
                modelBreakdown: UsageMath.modelShares(perModel),
                isSubAgent: session.isSubAgent ?? false
            )
            aggregator.add(
                sessionUsage,
                projectKey: session.projectKey,
                displayPath: ProjectDisplay.displayPath(cwd: session.projectPath, fallback: session.projectKey),
                name: ProjectDisplay.name(cwd: session.projectPath, fallback: session.projectKey)
            )
        }
        return aggregator.projects()
    }

    /// Inclusive lower-bound day key ("yyyy-MM-dd") for `timeframe`.
    static func breakdownCutoffDay(
        _ timeframe: BreakdownTimeframe,
        formatter: DateFormatter,
        calendar: Calendar,
        now: Date
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(timeframe.days - 1), to: today) ?? today
        return formatter.string(from: start)
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
    /// Working directory + git branch ride on every assistant record; used for
    /// project attribution in the breakdown (not for the aggregate token card).
    var cwd: String?
    var gitBranch: String?
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

/// `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` — the CLI-generated
/// session title. The only message-content-derived field Pulse reads, and only
/// when title capture is enabled.
private struct TitleLine: Decodable {
    var type: String?
    var aiTitle: String?
}
