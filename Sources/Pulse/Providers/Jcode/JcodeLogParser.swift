import Foundation

/// Incremental parser for `~/.jcode/sessions/session_*.json`.
///
/// jcode is a **harness, not a provider**: a jcode session runs against one of
/// the same accounts the Claude Code / Codex apps use. Its usage therefore
/// belongs on that *account's* tab, not on a tab of its own. This parser is
/// consumed by the account providers, filtered by `accountLabel`.
///
/// **Shape (verified 2026-08-27 against 3,089 live session files):** each
/// session is a single JSON object, not JSONL:
///
/// ```
/// { "id", "title", "model", "provider_key", "working_dir",
///   "messages": [ { "id", "role", "timestamp",
///                   "token_usage": { "input_tokens", "output_tokens",
///                                    "cache_read_input_tokens",
///                                    "cache_creation_input_tokens",
///                                    "account_label" } } ] }
/// ```
///
/// Four consequences drive this parser:
///
/// 1. **Account is per message, not per session.** `prefer_account_failover`
///    rotates accounts on a rate-limit error mid-turn, so one session can bill
///    both `claude-1` and `claude-2`. Entries carry the label individually and
///    a session's tokens can legitimately split across two tabs.
/// 2. **Sessions written before jcode recorded the label have none.** They are
///    attributed to `unattributedAccount` (the primary account) rather than
///    dropped, which would silently lose the entire pre-change history.
/// 3. **Model lives on the session, never the message**, and carries a routing
///    suffix (`claude-opus-5[1m]`) that must be stripped or pricing misses it.
/// 4. **Cache-write TTL is not recorded.** jcode requests 5m caching, so writes
///    are booked at the 5m rate (1.25x) and never the 1h rate (2x).
///
/// **Sub-agents.** A jcode sub-agent run is an ordinary session file whose
/// `parent_id` names the session that spawned it (measured 2026-08-28: 21 of
/// 3,156 files, carrying 18.2% of all jcode tokens). Two facts shape the
/// handling, both observed in the live data:
///
/// - **The trees nest** — 5 of 21 children have a parent that is itself a
///   child, so "sub-agent" is `parent_id != nil` at any depth, and project
///   attribution walks to the *root* ancestor rather than one level up.
/// - **A child's `working_dir` can differ from its parent's** (1 of 21 did).
///   Its usage is attributed to the project that *spawned* it, so "this
///   project's work cost X" stays true even when the agent ran elsewhere.
struct JcodeLogParser: Sendable {
    typealias Entry = ClaudeLogParser.Entry
    typealias SessionFile = ClaudeLogParser.SessionFile

    /// Account that inherits usage jcode never labelled. Everything written
    /// before the `account_label` field existed predates multi-account
    /// attribution, and `claude-1` is the account that ran it.
    static let unattributedAccount = "claude-1"

    let sessionsRoot: URL
    let captureTitles: Bool
    private let cache: FileAggregationCache<AccountSessions>

    /// One session file's parse, split by billed account. The split is stored
    /// rather than recomputed so each account provider reads the same cache.
    struct AccountSessions: Codable, Sendable, Equatable {
        /// account label -> that account's slice of this session.
        var byAccount: [String: SessionFile]
        /// This session's own id, unsuffixed — the key other sessions'
        /// `parentID` points at. Stored separately because `SessionFile`'s id
        /// is suffixed when a session billed two accounts.
        var sessionID: String?
        /// Spawning session's id, when this session is a sub-agent run.
        var parentID: String?
        /// Working directory as recorded on this session, before root-ancestor
        /// attribution rewrites it.
        var workingDir: String?
    }

    init(
        sessionsRoot: URL = AppPaths.home.appendingPathComponent(".jcode/sessions"),
        captureTitles: Bool = true,
        cacheName: String? = nil
    ) {
        self.sessionsRoot = sessionsRoot
        self.captureTitles = captureTitles
        self.cache = FileAggregationCache(name: cacheName ?? Self.defaultCacheName(captureTitles: captureTitles))
    }

    /// Cache file name for a mode.
    ///
    /// **v3 adds `parent_id` / sub-agent fields to the cached shape.** A v2
    /// cache decodes cleanly into the v3 shape with every new field `nil`,
    /// which is the dangerous case: no error, and every session reads as
    /// main-session forever, so the whole feature silently shows zero. The name
    /// is therefore bumped rather than migrated, forcing one re-parse.
    static func defaultCacheName(captureTitles: Bool) -> String {
        captureTitles ? "jcode-files-v3" : "jcode-files-v3-blind"
    }

    /// Every jcode session slice billed to any of `accountLabels`.
    ///
    /// Sub-agent sessions are re-pointed at their root ancestor's project
    /// before the account filter, so a spawned agent's tokens land on the
    /// project that spawned it even when it ran in a different directory.
    func sessions(for accountLabels: Set<String>, now: Date = .now) async -> [SessionFile] {
        guard !accountLabels.isEmpty else { return [] }
        let since = now.addingTimeInterval(-366 * 24 * 3600)
        let files = FileSnapshot.enumerate(root: sessionsRoot, pathExtension: "json", modifiedSince: since)
            .filter { $0.url.lastPathComponent.hasPrefix("session_") }
        guard !files.isEmpty else { return [] }
        let captureTitles = captureTitles
        let parsed = await cache.aggregates(for: files) {
            try Self.parseSession($0, captureTitles: captureTitles)
        }
        return Self.attributeToRootProjects(parsed).flatMap { session in
            accountLabels.compactMap { session.byAccount[$0] }
        }
    }

    // MARK: - Sub-agent attribution

    /// Marks every session with a `parentID` as a sub-agent and re-points it at
    /// its **root ancestor's** project. The walk is cycle-safe (session files
    /// are machine-written, but a cycle would otherwise hang the parse) and
    /// stops at the first ancestor missing from the set — a parent older than
    /// the 366-day file window is simply not there, and the child then keeps
    /// its own working directory rather than being dropped.
    static func attributeToRootProjects(_ parsed: [AccountSessions]) -> [AccountSessions] {
        var byID: [String: AccountSessions] = [:]
        for session in parsed {
            if let id = session.sessionID { byID[id] = session }
        }

        return parsed.map { session in
            guard session.parentID != nil else { return session }
            var session = session

            // Walk to the root. `seen` guards a cycle; the hop limit guards a
            // chain long enough that the data is nonsense either way.
            var seen: Set<String> = session.sessionID.map { [$0] } ?? []
            var current = session
            while let parentID = current.parentID, !seen.contains(parentID), seen.count < 64 {
                seen.insert(parentID)
                guard let parent = byID[parentID] else { break }
                current = parent
            }

            let rootDir = current.workingDir ?? session.workingDir
            session.byAccount = session.byAccount.mapValues { slice in
                var slice = slice
                slice.projectKey = rootDir ?? "unknown"
                slice.projectPath = rootDir
                slice.isSubAgent = true
                return slice
            }
            return session
        }
    }

    // MARK: - Per-file parse

    static func parseSession(_ url: URL, captureTitles: Bool) throws -> AccountSessions {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(SessionJSON.self, from: data)

        let model = ModelNames.normalizedJcodeModel(file.model)
        let formatter = ClaudeLogParser.localDayFormatter()
        let calendar = Calendar.current
        let iso = ClaudeISO8601()

        var seen = Set<String>()
        var entriesByAccount: [String: [Entry]] = [:]
        var spanByAccount: [String: (first: Date, last: Date)] = [:]

        for message in file.messages ?? [] {
            guard let usage = message.tokenUsage else { continue }
            // jcode writes each assistant turn once (no streamed partials), so
            // a repeated id means a re-saved file: first wins.
            if let id = message.id, !seen.insert(id).inserted { continue }
            guard let stamp = message.timestamp, let date = iso.date(from: stamp) else { continue }

            let account = usage.accountLabel ?? unattributedAccount
            let span = spanByAccount[account]
            spanByAccount[account] = (
                first: min(span?.first ?? date, date),
                last: max(span?.last ?? date, date)
            )
            entriesByAccount[account, default: []].append(
                Entry(
                    key: message.id,
                    day: formatter.string(from: date),
                    model: model,
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheRead: usage.cacheReadInputTokens ?? 0,
                    cacheWrite5m: usage.cacheCreationInputTokens ?? 0,
                    cacheWrite1h: 0,
                    hour: calendar.component(.hour, from: date)
                )
            )
        }

        let sessionID = file.id ?? url.deletingPathExtension().lastPathComponent
        var byAccount: [String: SessionFile] = [:]
        for (account, entries) in entriesByAccount {
            let span = spanByAccount[account]
            byAccount[account] = SessionFile(
                projectKey: file.workingDir ?? "unknown",
                projectPath: file.workingDir,
                // A session that billed two accounts appears once per account;
                // the id is suffixed so the two slices never collide in the
                // breakdown's session list.
                sessionID: entriesByAccount.count > 1 ? "\(sessionID)#\(account)" : sessionID,
                gitBranch: nil,
                title: captureTitles ? file.title : nil,
                firstActivity: span?.first,
                lastActivity: span?.last,
                entries: entries,
                // Set by `attributeToRootProjects`, which is the only place
                // with the whole session set needed to resolve a parent.
                isSubAgent: file.parentID != nil
            )
        }
        return AccountSessions(
            byAccount: byAccount,
            sessionID: sessionID,
            parentID: file.parentID,
            workingDir: file.workingDir
        )
    }

    // MARK: - Targeted decode

    /// Only the fields Pulse needs. `messages[].content` is deliberately absent
    /// so conversation text is never decoded, let alone cached to disk.
    private struct SessionJSON: Decodable {
        var id: String?
        var title: String?
        var model: String?
        var workingDir: String?
        var parentID: String?
        var messages: [Message]?

        enum CodingKeys: String, CodingKey {
            case id, title, model, messages
            case workingDir = "working_dir"
            case parentID = "parent_id"
        }

        struct Message: Decodable {
            var id: String?
            var timestamp: String?
            var tokenUsage: Usage?

            enum CodingKeys: String, CodingKey {
                case id, timestamp
                case tokenUsage = "token_usage"
            }
        }

        struct Usage: Decodable {
            var inputTokens: Int64?
            var outputTokens: Int64?
            var cacheReadInputTokens: Int64?
            var cacheCreationInputTokens: Int64?
            var accountLabel: String?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case accountLabel = "account_label"
            }
        }
    }
}
