import Foundation
import Testing
@testable import Pulse

// Fixtures are fabricated: real jcode session *shapes* (docs/HANDOFF-jcode-subagent-attribution.md)
// with fake ids and paths — never real session files or real token counts.
//
// What these cover, and why each exists:
//
// - `parent_id` is what makes a session a sub-agent. Nothing else does: not the
//   model, not the account, not the working directory. Measured 2026-08-28,
//   every jcode sub-agent on the machine ran a Claude model, but keying off the
//   model would break the first time one runs on OpenAI.
// - Sub-agent trees **nest** (5 of 21 children had a child parent), so
//   attribution walks to the *root* ancestor, not one level up.
// - A child's `working_dir` can **differ** from its parent's (1 of 21 did), so
//   the walk changes real numbers rather than being a no-op.

// MARK: - Fixture writing

private func writeSessionFile(
    in dir: URL,
    id: String,
    parentID: String? = nil,
    workingDir: String,
    model: String = "claude-opus-5",
    account: String? = "claude-1",
    day: String = "2026-06-18",
    input: Int64 = 0,
    output: Int64 = 0,
    cacheRead: Int64 = 0,
    cacheWrite: Int64 = 0
) throws -> URL {
    var session: [String: Any] = [
        "id": id,
        "title": "Session \(id)",
        "model": model,
        "working_dir": workingDir,
        "messages": [
            [
                "id": "\(id)-m1",
                "role": "assistant",
                "timestamp": "\(day)T10:00:00Z",
                "token_usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheWrite,
                    "account_label": account as Any,
                ] as [String: Any],
            ] as [String: Any],
        ],
    ]
    if let parentID { session["parent_id"] = parentID }

    let url = dir.appendingPathComponent("session_\(id).json")
    let data = try JSONSerialization.data(withJSONObject: session)
    try data.write(to: url)
    return url
}

private func parse(_ url: URL) throws -> JcodeLogParser.AccountSessions {
    try JcodeLogParser.parseSession(url, captureTitles: true)
}

private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pulse-jcode-subagent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Parse-level detection

@Suite("jcode sub-agent detection")
struct JcodeSubAgentDetectionTests {
    @Test func rootSessionIsNotSubAgent() throws {
        let dir = try makeTempDir()
        let url = try writeSessionFile(in: dir, id: "root", workingDir: "/w/alpha", input: 100)
        let parsed = try parse(url)

        #expect(parsed.parentID == nil)
        #expect(parsed.sessionID == "root")
        #expect(parsed.byAccount["claude-1"]?.isSubAgent == false)
    }

    @Test func parentIDMarksSessionAsSubAgent() throws {
        let dir = try makeTempDir()
        let url = try writeSessionFile(in: dir, id: "child", parentID: "root", workingDir: "/w/alpha", input: 50)
        let parsed = try parse(url)

        #expect(parsed.parentID == "root")
        #expect(parsed.byAccount["claude-1"]?.isSubAgent == true)
    }

    /// Sub-agent-ness must key off `parent_id` alone. An OpenAI-model child is
    /// a sub-agent exactly as a Claude one is — the case that cannot be
    /// verified against live data yet, since no OpenAI sub-agent exists on this
    /// machine, so it is pinned in a fixture instead.
    @Test func detectionIsModelAgnostic() throws {
        let dir = try makeTempDir()
        let url = try writeSessionFile(
            in: dir, id: "gptchild", parentID: "root",
            workingDir: "/w/alpha", model: "gpt-5.6", input: 10
        )
        #expect(try parse(url).byAccount["claude-1"]?.isSubAgent == true)
    }
}

// MARK: - Root-ancestor attribution

@Suite("jcode sub-agent attribution")
struct JcodeSubAgentAttributionTests {
    /// The measured real case: a child that ran in a different directory from
    /// its parent. Its tokens belong to the project that *spawned* it.
    @Test func childInheritsParentProjectWhenWorkingDirDiffers() throws {
        let dir = try makeTempDir()
        let root = try parse(try writeSessionFile(in: dir, id: "root", workingDir: "/w/delist", input: 100))
        let child = try parse(try writeSessionFile(
            in: dir, id: "child", parentID: "root", workingDir: "/w/dicdrepo", input: 40
        ))

        let attributed = JcodeLogParser.attributeToRootProjects([root, child])
        let childSlice = try #require(attributed.first { $0.sessionID == "child" }?.byAccount["claude-1"])

        #expect(childSlice.projectKey == "/w/delist")
        #expect(childSlice.projectPath == "/w/delist")
        #expect(childSlice.isSubAgent == true)
    }

    /// Nesting: a grandchild resolves to the **root**, not to its immediate
    /// parent. Attributing one level up would land it on the middle session's
    /// project, which is itself sub-agent work.
    @Test func grandchildResolvesToRootNotImmediateParent() throws {
        let dir = try makeTempDir()
        let root = try parse(try writeSessionFile(in: dir, id: "root", workingDir: "/w/root", input: 100))
        let mid = try parse(try writeSessionFile(in: dir, id: "mid", parentID: "root", workingDir: "/w/mid", input: 50))
        let leaf = try parse(try writeSessionFile(in: dir, id: "leaf", parentID: "mid", workingDir: "/w/leaf", input: 25))

        let attributed = JcodeLogParser.attributeToRootProjects([root, mid, leaf])
        let leafSlice = try #require(attributed.first { $0.sessionID == "leaf" }?.byAccount["claude-1"])
        let midSlice = try #require(attributed.first { $0.sessionID == "mid" }?.byAccount["claude-1"])

        #expect(leafSlice.projectKey == "/w/root")
        #expect(midSlice.projectKey == "/w/root")
        #expect(leafSlice.isSubAgent == true)
    }

    /// A parent older than the 366-day file window is simply absent. The child
    /// must still count as a sub-agent and keep its own directory rather than
    /// being dropped or landing on "unknown".
    @Test func orphanKeepsOwnProjectAndStaysSubAgent() throws {
        let dir = try makeTempDir()
        let orphan = try parse(try writeSessionFile(
            in: dir, id: "orphan", parentID: "long-gone", workingDir: "/w/alpha", input: 30
        ))

        let attributed = JcodeLogParser.attributeToRootProjects([orphan])
        let slice = try #require(attributed.first?.byAccount["claude-1"])

        #expect(slice.projectKey == "/w/alpha")
        #expect(slice.isSubAgent == true)
    }

    /// Session files are machine-written, so a cycle should never occur — but a
    /// naive walk would hang forever if one did, taking the whole refresh with
    /// it. The guard is asserted, not assumed.
    @Test func cyclicParentChainTerminates() throws {
        let dir = try makeTempDir()
        let a = try parse(try writeSessionFile(in: dir, id: "a", parentID: "b", workingDir: "/w/a", input: 10))
        let b = try parse(try writeSessionFile(in: dir, id: "b", parentID: "a", workingDir: "/w/b", input: 10))

        let attributed = JcodeLogParser.attributeToRootProjects([a, b])
        #expect(attributed.count == 2)
        #expect(attributed.allSatisfy { $0.byAccount["claude-1"]?.isSubAgent == true })
    }

    @Test func rootSessionsAreLeftUntouched() throws {
        let dir = try makeTempDir()
        let root = try parse(try writeSessionFile(in: dir, id: "root", workingDir: "/w/alpha", input: 100))
        let attributed = JcodeLogParser.attributeToRootProjects([root])
        let slice = try #require(attributed.first?.byAccount["claude-1"])

        #expect(slice.projectKey == "/w/alpha")
        #expect(slice.isSubAgent == false)
    }
}

// MARK: - Rollup: totals and costs

@Suite("Sub-agent rollups")
struct SubAgentRollupTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        return calendar
    }

    private var now: Date {
        let formatter = ClaudeLogParser.localDayFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: "2026-06-18")!.addingTimeInterval(12 * 3600)
    }

    private func entry(day: String, input: Int64, output: Int64 = 0, key: String? = nil) -> ClaudeLogParser.Entry {
        ClaudeLogParser.Entry(
            key: key, day: day, model: "claude-opus-4-8",
            input: input, output: output, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, hour: 10
        )
    }

    private func session(
        key: String, id: String, entries: [ClaudeLogParser.Entry], isSubAgent: Bool
    ) -> ClaudeLogParser.SessionFile {
        ClaudeLogParser.SessionFile(
            projectKey: key, projectPath: key, sessionID: id, gitBranch: nil, title: nil,
            firstActivity: now, lastActivity: now, entries: entries, isSubAgent: isSubAgent
        )
    }

    /// The card's sub-agent figures are a **subset** of the headline row. If
    /// they were ever an addition, main + sub would exceed the observed total.
    @Test func cardSubAgentSliceIsSubsetOfTotals() throws {
        let main = session(key: "-p", id: "m", entries: [entry(day: "2026-06-18", input: 800, output: 80)], isSubAgent: false)
        let sub = session(key: "-p", id: "s", entries: [entry(day: "2026-06-18", input: 200, output: 20)], isSubAgent: true)

        let tokens = try #require(
            ClaudeLogParser.rollUp(sessions: [main, sub], calendar: calendar, now: now).tokens
        )

        #expect(tokens.today.input == 1000)
        #expect(tokens.todaySubAgent.input == 200)
        #expect(tokens.thisMonth.output == 100)
        #expect(tokens.thisMonthSubAgent.output == 20)
        #expect(tokens.hasSubAgentUsage)
        // The reconciliation that matters: main + sub == all.
        #expect(tokens.today.input - tokens.todaySubAgent.input == 800)
    }

    @Test func noSubAgentSessionsMeansNoSubAgentUsage() throws {
        let main = session(key: "-p", id: "m", entries: [entry(day: "2026-06-18", input: 500)], isSubAgent: false)
        let tokens = try #require(ClaudeLogParser.rollUp(sessions: [main], calendar: calendar, now: now).tokens)

        #expect(tokens.today.input == 500)
        #expect(tokens.todaySubAgent.total == 0)
        #expect(!tokens.hasSubAgentUsage)
    }

    /// The entry-list overload has no session context, so its usage is
    /// main-session by definition — the Cursor/Copilot path must not start
    /// reporting phantom sub-agent tokens.
    @Test func entryListRollupReportsNoSubAgentUsage() throws {
        let tokens = try #require(
            ClaudeLogParser.rollUp([[entry(day: "2026-06-18", input: 300)]], calendar: calendar, now: now).tokens
        )
        #expect(tokens.today.input == 300)
        #expect(!tokens.hasSubAgentUsage)
    }

    @Test func breakdownSplitsProjectTotalsAndCost() throws {
        let main = session(key: "-p", id: "m", entries: [entry(day: "2026-06-18", input: 800, output: 80)], isSubAgent: false)
        let sub = session(key: "-p", id: "s", entries: [entry(day: "2026-06-18", input: 200, output: 20)], isSubAgent: true)

        let projects = ClaudeLogParser.rollUpBreakdown(
            [main, sub], timeframe: .last7Days, calendar: calendar, now: now
        )
        let project = try #require(projects.first)

        #expect(project.sessionCount == 2)
        #expect(project.subAgentSessionCount == 1)
        #expect(project.totals.input == 1000)
        #expect(project.subAgentTotals.input == 200)
        #expect(project.mainTotals.input == 800)
        #expect(project.mainTotals.output == 80)
        #expect(project.hasSubAgentUsage)

        // Cost splits across buckets and reconciles: main + sub == total.
        let total = try #require(project.totals.costUSD)
        let subCost = try #require(project.subAgentTotals.costUSD)
        let mainCost = try #require(project.mainTotals.costUSD)
        #expect(subCost > 0)
        #expect(abs(mainCost + subCost - total) < 1e-9)
        // 200 of 1000 input tokens, at one price, is a fifth of the cost.
        #expect(abs(subCost / total - 0.2) < 0.05)

        // The session rows carry the flag the table renders from.
        #expect(project.sessions.first { $0.id == "s" }?.isSubAgent == true)
        #expect(project.sessions.first { $0.id == "m" }?.isSubAgent == false)
    }

    /// The column gate: a provider with no sub-agent sessions must not grow two
    /// columns of em dashes.
    @Test func breakdownHidesSubAgentColumnsWithoutSubAgents() throws {
        let main = session(key: "-p", id: "m", entries: [entry(day: "2026-06-18", input: 100)], isSubAgent: false)
        let projects = ClaudeLogParser.rollUpBreakdown([main], timeframe: .last7Days, calendar: calendar, now: now)
        let breakdown = ProjectBreakdown(
            providerID: .claude, timeframe: .last7Days, generatedAt: now,
            projects: projects,
            grandTotal: projects.reduce(into: TokenTotals()) { $0.add($1.totals) },
            showsCost: true
        )

        #expect(!breakdown.showsSubAgents)
        #expect(breakdown.subAgentTotal.total == 0)
    }

    @Test func breakdownGrandSubAgentTotalSumsProjects() throws {
        let a = session(key: "-a", id: "a1", entries: [entry(day: "2026-06-18", input: 100)], isSubAgent: true)
        let b = session(key: "-b", id: "b1", entries: [entry(day: "2026-06-18", input: 300)], isSubAgent: true)
        let c = session(key: "-b", id: "b2", entries: [entry(day: "2026-06-18", input: 600)], isSubAgent: false)

        let projects = ClaudeLogParser.rollUpBreakdown([a, b, c], timeframe: .last7Days, calendar: calendar, now: now)
        let breakdown = ProjectBreakdown(
            providerID: .claude, timeframe: .last7Days, generatedAt: now,
            projects: projects,
            grandTotal: projects.reduce(into: TokenTotals()) { $0.add($1.totals) },
            showsCost: true
        )

        #expect(breakdown.showsSubAgents)
        #expect(breakdown.grandTotal.input == 1000)
        #expect(breakdown.subAgentTotal.input == 400)
    }

    /// A project whose model carries no price must report `nil` main cost, not
    /// a confident `$0` — the direction `mainTotals` is easy to get wrong.
    @Test func unpricedProjectKeepsNilMainCost() {
        var project = ProjectUsage(
            id: "-p", displayPath: "/p", name: "p",
            totals: TokenTotals(input: 100, costUSD: nil),
            sessionCount: 1, lastActivity: now, isActive: false
        )
        project.subAgentTotals = TokenTotals(input: 40, costUSD: nil)

        #expect(project.mainTotals.input == 60)
        #expect(project.mainTotals.costUSD == nil)
    }
}

// MARK: - Cache versioning

@Suite("jcode cache versioning")
struct JcodeCacheVersionTests {
    /// The v2 cache decodes into the v3 shape without error, every new field
    /// `nil`, so a missed bump shows zero sub-agent usage forever with no
    /// symptom. The name is asserted rather than trusted.
    @Test func cacheNameIsBumpedPastV2() {
        #expect(JcodeLogParser.defaultCacheName(captureTitles: true) == "jcode-files-v3")
        #expect(JcodeLogParser.defaultCacheName(captureTitles: false) == "jcode-files-v3-blind")
    }

    /// The silent-failure mode itself: prove a v2-shaped aggregate really does
    /// decode into the v3 type. If it threw, a bump would be unnecessary; it
    /// does not, which is exactly why the bump is required.
    @Test func v2ShapedAggregateDecodesWithNilSubAgentFields() throws {
        let v2JSON = """
        {"byAccount":{"claude-1":{"projectKey":"/w/a","sessionID":"s1","entries":[]}}}
        """
        let decoded = try JSONDecoder().decode(
            JcodeLogParser.AccountSessions.self, from: Data(v2JSON.utf8)
        )

        #expect(decoded.parentID == nil)
        #expect(decoded.sessionID == nil)
        #expect(decoded.byAccount["claude-1"]?.isSubAgent == nil)
    }
}
