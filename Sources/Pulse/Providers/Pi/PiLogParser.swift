import Foundation

/// Incremental parser for `~/.pi/agent/sessions/<encoded-cwd>/<stamp>_<uuid>.jsonl`.
///
/// Like jcode, pi is a **harness, not a provider**: a pi session runs against
/// one of the same Anthropic accounts the Claude Code app uses, so its usage
/// belongs on that *account's* tab rather than a tab of its own. This parser is
/// consumed by `ClaudeProvider`, filtered by account label.
///
/// **Shape (verified 2026-09-01 against 40 live session files, 1,420 message
/// records).** Unlike jcode's single-JSON-object sessions, a pi session is
/// JSONL, one record per line, four record types (`session`, `model_change`,
/// `thinking_level_change`, `message`):
///
/// ```
/// {"type":"session","version":3,"id":"<uuid>","timestamp":"…Z","cwd":"/abs/path"}
/// {"type":"message","id":"f0cf68a2","parentId":"…","timestamp":"…Z",
///  "message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5",
///             "usage":{"input":2,"output":162,"cacheRead":2436,"cacheWrite":17252,
///                      "cacheWrite1h":0,"totalTokens":19852,"reasoning":16,
///                      "cost":{"input":…,"output":…,"total":…}}}}
/// ```
///
/// Five consequences drive this parser:
///
/// 1. **`message.provider` is the account key**, matching a top-level key of
///    `~/.pi/agent/auth.json` (`anthropic`, `anthropic-2`, `anthropic-3`,
///    `openai-codex`, …). It is per message, not per session, because pi can
///    switch account mid-session, so one file can bill two accounts — the same
///    split jcode needs.
/// 2. **pi records no email anywhere**, so the key alone says nothing about
///    *which* account it is. `PiAccountResolver` answers that against
///    Anthropic's own profile endpoint; this parser takes the resolved set of
///    keys and never guesses. Ordering was tried first and was backwards on the
///    machine it was written on — see `PiAccountResolver` for the measurement.
/// 3. **`cwd` lives only on the `session` record**, once, at the top of the
///    file — never on a message. The directory name is an encoded copy of it
///    and is used as the grouping key.
/// 4. **`message.id` is 8 hex chars**, unique within a file but not globally
///    guaranteed, so the dedup key is namespaced with the session id before it
///    reaches `rollUp`'s global dedup map.
/// 5. **pi has no sub-agents.** There is no session-level `parent_id`; the
///    `parentId` on a record is the conversation DAG's previous record, not a
///    spawning session. Every pi session is therefore a main session, and the
///    token card's sub-agent rows stay hidden for an account whose only
///    harness is pi.
///
/// **Cost is recomputed, not read.** pi writes an exact `usage.cost` per
/// message, but every other surface in Pulse prices from `ModelPricing`; mixing
/// the two on one card would make two rows incomparable. pi's own figure is
/// left on disk deliberately.
struct PiLogParser: Sendable {
    typealias Entry = ClaudeLogParser.Entry
    typealias SessionFile = ClaudeLogParser.SessionFile

    let sessionsRoot: URL
    private let cache: FileAggregationCache<AccountSessions>

    /// One session file's parse, split by billed account — same shape as
    /// jcode's, minus the sub-agent fields pi has no equivalent for.
    struct AccountSessions: Codable, Sendable, Equatable {
        /// account label -> that account's slice of this session.
        var byAccount: [String: SessionFile]
    }

    init(
        sessionsRoot: URL = AppPaths.home.appendingPathComponent(".pi/agent/sessions"),
        cacheName: String? = nil
    ) {
        self.sessionsRoot = sessionsRoot
        // **v2 re-keys `byAccount` from a `claude-N` label to pi's own provider
        // key.** A v1 cache decodes into the v2 shape without error and then
        // matches nothing, so every unchanged file silently contributes zero -
        // observed here as 37 sessions collapsing to 3. The name is bumped
        // rather than migrated, forcing one re-parse.
        self.cache = FileAggregationCache(name: cacheName ?? "pi-files-v2")
    }

    /// Every pi session slice billed to one of `providerKeys`.
    ///
    /// The caller passes the keys `PiAccountResolver` identified as its
    /// account. An empty set returns nothing: unresolved usage is dropped, not
    /// parked on a plausible tab.
    func sessions(for providerKeys: Set<String>, now: Date = .now) async -> [SessionFile] {
        guard !providerKeys.isEmpty else { return [] }
        let since = now.addingTimeInterval(-366 * 24 * 3600)
        let files = FileSnapshot.enumerate(root: sessionsRoot, pathExtension: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return [] }
        let parsed = await cache.aggregates(for: files) { try Self.parseSession($0) }
        return parsed.flatMap { session in
            providerKeys.compactMap { session.byAccount[$0] }
        }
    }

    // MARK: - Per-file parse

    static func parseSession(_ url: URL) throws -> AccountSessions {
        let formatter = ClaudeLogParser.localDayFormatter()
        let calendar = Calendar.current
        let iso = ClaudeISO8601()

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var entriesByAccount: [String: [Entry]] = [:]
        var spanByAccount: [String: (first: Date, last: Date)] = [:]

        try JSONLines.forEachLine(of: url) { line in
            // Cheap prefilter: only two of the four record types matter, and
            // the vast majority of lines are user/tool messages with no usage.
            if line.contains("\"type\":\"session\"") {
                if let record = JSONLines.decode(SessionLine.self, from: line), record.type == "session" {
                    if let id = record.id, !id.isEmpty { sessionID = id }
                    if let dir = record.cwd, !dir.isEmpty { cwd = dir }
                }
                return
            }
            guard line.contains("\"usage\"") else { return }
            guard let record = JSONLines.decode(MessageLine.self, from: line),
                  record.type == "message",
                  let message = record.message,
                  let usage = message.usage,
                  let stamp = record.timestamp,
                  let date = iso.date(from: stamp)
            else { return }
            // Slices are keyed by pi's own provider key; who that key *is* gets
            // decided by the resolver, not here, so the parse (and its on-disk
            // cache) stays valid across a re-login that changes the answer.
            guard let account = message.provider, PiAccountResolver.isAnthropicKey(account) else { return }
            // pi writes a usage record for turns that never billed anything
            // (12 of 782 assistant records on 2026-09-01 were all-zero, from
            // aborted or failed calls). Keeping them adds nothing to the totals
            // but does add phantom zero-token *sessions* to the breakdown, and
            // an account whose only pi work failed would get a whole tab's
            // worth of empty rows.
            let billed = (usage.input ?? 0) + (usage.output ?? 0)
                + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0)
            guard billed > 0 else { return }

            let span = spanByAccount[account]
            spanByAccount[account] = (
                first: min(span?.first ?? date, date),
                last: max(span?.last ?? date, date)
            )
            entriesByAccount[account, default: []].append(
                Entry(
                    // Namespaced: an 8-hex record id is unique per file only.
                    key: record.id.map { "\(sessionID)|\($0)" },
                    day: formatter.string(from: date),
                    model: ModelNames.normalizedJcodeModel(message.model),
                    input: usage.input ?? 0,
                    output: usage.output ?? 0,
                    cacheRead: usage.cacheRead ?? 0,
                    // pi reports the two cache TTLs separately and `cacheWrite`
                    // is the 5m bucket, so the 1h premium is priced correctly
                    // rather than assumed away.
                    cacheWrite5m: max((usage.cacheWrite ?? 0) - (usage.cacheWrite1h ?? 0), 0),
                    cacheWrite1h: usage.cacheWrite1h ?? 0,
                    hour: calendar.component(.hour, from: date)
                )
            )
        }

        var byAccount: [String: SessionFile] = [:]
        for (account, entries) in entriesByAccount {
            let span = spanByAccount[account]
            byAccount[account] = SessionFile(
                projectKey: cwd ?? url.deletingLastPathComponent().lastPathComponent,
                projectPath: cwd,
                // A session that billed two accounts appears once per account;
                // the suffix keeps the two slices apart in the breakdown list.
                sessionID: entriesByAccount.count > 1 ? "\(sessionID)#\(account)" : sessionID,
                gitBranch: nil,
                // pi writes no session title record, so there is nothing to
                // capture and nothing for the title setting to gate.
                title: nil,
                firstActivity: span?.first,
                lastActivity: span?.last,
                entries: entries,
                isSubAgent: false
            )
        }
        return AccountSessions(byAccount: byAccount)
    }

    // MARK: - Targeted decode

    /// Only the fields Pulse needs. `message.content` is deliberately absent,
    /// so conversation text is never decoded, let alone cached to disk.
    private struct SessionLine: Decodable {
        var type: String?
        var id: String?
        var cwd: String?
    }

    private struct MessageLine: Decodable {
        var type: String?
        var id: String?
        var timestamp: String?
        var message: Message?

        struct Message: Decodable {
            var role: String?
            var provider: String?
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var input: Int64?
            var output: Int64?
            var cacheRead: Int64?
            var cacheWrite: Int64?
            var cacheWrite1h: Int64?
        }
    }
}
