// Assertions for jcode sub-agent attribution, compiled against the real
// sources by scripts/verify-subagent-attribution.sh. Prints "ALL PASS" only
// when every check holds; the script's planted-defect run requires each defect
// to break at least one of these.
//
// Fabricated fixtures throughout, plus one optional read-only pass over the
// live ~/.jcode/sessions tree to reproduce the measured 18.2% figure.

import Foundation

var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

@MainActor
func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

// MARK: - Fixtures

let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pulse-subagent-harness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

func writeSession(
    id: String,
    parentID: String? = nil,
    workingDir: String,
    model: String = "claude-opus-5",
    input: Int64 = 100,
    output: Int64 = 10
) -> URL {
    var session: [String: Any] = [
        "id": id,
        "title": "Session \(id)",
        "model": model,
        "working_dir": workingDir,
        "messages": [[
            "id": "\(id)-m1",
            "role": "assistant",
            "timestamp": "2026-06-18T10:00:00Z",
            "token_usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "account_label": "claude-1",
            ] as [String: Any],
        ] as [String: Any]],
    ]
    if let parentID { session["parent_id"] = parentID }
    let url = workDir.appendingPathComponent("session_\(id).json")
    try! JSONSerialization.data(withJSONObject: session).write(to: url)
    return url
}

func parse(_ url: URL) -> JcodeLogParser.AccountSessions {
    try! JcodeLogParser.parseSession(url, captureTitles: true)
}

// MARK: - 1. parent_id detection

let rootParsed = parse(writeSession(id: "root", workingDir: "/w/delist"))
let childParsed = parse(writeSession(id: "child", parentID: "root", workingDir: "/w/dicdrepo"))

check(rootParsed.byAccount["claude-1"]?.isSubAgent == false, "root session must not be a sub-agent")
check(childParsed.byAccount["claude-1"]?.isSubAgent == true, "parent_id must mark a session as sub-agent")

// Model-agnostic: an OpenAI-model child is a sub-agent too. No such session
// exists on this machine, so it is pinned in a fixture rather than measured.
let gptChild = parse(writeSession(id: "gptchild", parentID: "root", workingDir: "/w/x", model: "gpt-5.6"))
check(gptChild.byAccount["claude-1"]?.isSubAgent == true, "detection must not depend on the model")

// MARK: - 2. Root-ancestor attribution

let attributed = JcodeLogParser.attributeToRootProjects([rootParsed, childParsed])
let childSlice = attributed.first { $0.sessionID == "child" }!.byAccount["claude-1"]!
checkEqual(childSlice.projectKey, "/w/delist", "child with a different working_dir attributes to the spawning project")

// Nesting: a grandchild resolves to the root, never to its immediate parent.
let midParsed = parse(writeSession(id: "mid", parentID: "root2", workingDir: "/w/mid"))
let leafParsed = parse(writeSession(id: "leaf", parentID: "mid", workingDir: "/w/leaf"))
let root2Parsed = parse(writeSession(id: "root2", workingDir: "/w/root2"))
let nested = JcodeLogParser.attributeToRootProjects([root2Parsed, midParsed, leafParsed])
let leafSlice = nested.first { $0.sessionID == "leaf" }!.byAccount["claude-1"]!
checkEqual(leafSlice.projectKey, "/w/root2", "grandchild attributes to the ROOT ancestor, not one level up")

// Orphan: parent outside the file window. Still a sub-agent, keeps its own dir.
let orphan = parse(writeSession(id: "orphan", parentID: "long-gone", workingDir: "/w/alpha"))
let orphanSlice = JcodeLogParser.attributeToRootProjects([orphan]).first!.byAccount["claude-1"]!
checkEqual(orphanSlice.projectKey, "/w/alpha", "orphan keeps its own project")
check(orphanSlice.isSubAgent == true, "orphan is still a sub-agent")

// Cycle guard: reaching this line at all proves termination.
let cycleA = parse(writeSession(id: "cyc-a", parentID: "cyc-b", workingDir: "/w/a"))
let cycleB = parse(writeSession(id: "cyc-b", parentID: "cyc-a", workingDir: "/w/b"))
let cycled = JcodeLogParser.attributeToRootProjects([cycleA, cycleB])
checkEqual(cycled.count, 2, "cyclic parent chain terminates and loses no session")

// MARK: - 3. Cache versioning

checkEqual(JcodeLogParser.defaultCacheName(captureTitles: true), "jcode-files-v3", "cache name must be bumped past v2")
checkEqual(JcodeLogParser.defaultCacheName(captureTitles: false), "jcode-files-v3-blind", "blind cache name must be bumped past v2")

// The silent-failure mode itself: a v2-shaped aggregate decodes cleanly into
// the v3 type with nil sub-agent fields, which is exactly why the bump matters.
let v2JSON = #"{"byAccount":{"claude-1":{"projectKey":"/w/a","sessionID":"s1","entries":[]}}}"#
let decodedV2 = try! JSONDecoder().decode(JcodeLogParser.AccountSessions.self, from: Data(v2JSON.utf8))
check(decodedV2.parentID == nil, "v2 aggregate decodes with nil parentID")
check(decodedV2.byAccount["claude-1"]?.isSubAgent == nil, "v2 aggregate decodes with nil isSubAgent")

// MARK: - 4. Rollups: card + breakdown

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
let dayFormatter = ClaudeLogParser.localDayFormatter()
dayFormatter.calendar = calendar
dayFormatter.timeZone = calendar.timeZone
let now = dayFormatter.date(from: "2026-06-18")!.addingTimeInterval(12 * 3600)

func entry(_ input: Int64, _ output: Int64) -> ClaudeLogParser.Entry {
    ClaudeLogParser.Entry(
        key: nil, day: "2026-06-18", model: "claude-opus-4-8",
        input: input, output: output, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, hour: 10
    )
}

func sessionFile(_ id: String, _ entries: [ClaudeLogParser.Entry], sub: Bool) -> ClaudeLogParser.SessionFile {
    ClaudeLogParser.SessionFile(
        projectKey: "-p", projectPath: "/p", sessionID: id, gitBranch: nil, title: nil,
        firstActivity: now, lastActivity: now, entries: entries, isSubAgent: sub
    )
}

let mainSession = sessionFile("m", [entry(800, 80)], sub: false)
let subSession = sessionFile("s", [entry(200, 20)], sub: true)

let tokens = ClaudeLogParser.rollUp(sessions: [mainSession, subSession], calendar: calendar, now: now).tokens!
checkEqual(tokens.today.input, 1000, "card total includes sub-agent tokens")
checkEqual(tokens.todaySubAgent.input, 200, "card sub-agent slice")
checkEqual(tokens.today.input - tokens.todaySubAgent.input, 800, "main + sub reconcile to the total")
check(tokens.hasSubAgentUsage, "sub-agent usage is detected")

let mainOnly = ClaudeLogParser.rollUp(sessions: [mainSession], calendar: calendar, now: now).tokens!
check(!mainOnly.hasSubAgentUsage, "no sub-agent sessions means no sub-agent usage")

let entryListOnly = ClaudeLogParser.rollUp([[entry(300, 30)]], calendar: calendar, now: now).tokens!
check(!entryListOnly.hasSubAgentUsage, "entry-list rollup reports no phantom sub-agent usage")

let projects = ClaudeLogParser.rollUpBreakdown(
    [mainSession, subSession], timeframe: .last7Days, calendar: calendar, now: now
)
let project = projects.first!
checkEqual(project.sessionCount, 2, "project session count")
checkEqual(project.subAgentSessionCount, 1, "project sub-agent session count")
checkEqual(project.totals.input, 1000, "project total input")
checkEqual(project.subAgentTotals.input, 200, "project sub-agent input")
checkEqual(project.mainTotals.input, 800, "project main input")

let totalCost = project.totals.costUSD!
let subCost = project.subAgentTotals.costUSD!
let mainCost = project.mainTotals.costUSD!
check(subCost > 0, "sub-agent cost is priced")
check(abs(mainCost + subCost - totalCost) < 1e-9, "cost splits reconcile: main + sub == total")
check(abs(subCost / totalCost - 0.2) < 0.05, "sub-agent cost is ~20% at a 200/1000 token split")

check(project.sessions.first { $0.id == "s" }?.isSubAgent == true, "sub-agent flag reaches the session row")
check(project.sessions.first { $0.id == "m" }?.isSubAgent == false, "main session row is not flagged")

let breakdown = ProjectBreakdown(
    providerID: .claude, timeframe: .last7Days, generatedAt: now,
    projects: projects,
    grandTotal: projects.reduce(into: TokenTotals()) { $0.add($1.totals) },
    showsCost: true
)
check(breakdown.showsSubAgents, "sub-agent columns show when sub-agents exist")
checkEqual(breakdown.subAgentTotal.input, 200, "breakdown sub-agent grand total")

let mainOnlyProjects = ClaudeLogParser.rollUpBreakdown(
    [mainSession], timeframe: .last7Days, calendar: calendar, now: now
)
let mainOnlyBreakdown = ProjectBreakdown(
    providerID: .claude, timeframe: .last7Days, generatedAt: now,
    projects: mainOnlyProjects,
    grandTotal: mainOnlyProjects.reduce(into: TokenTotals()) { $0.add($1.totals) },
    showsCost: true
)
check(!mainOnlyBreakdown.showsSubAgents, "sub-agent columns stay hidden without sub-agents")

// Unpriced project: main cost must stay nil, never a confident $0.
var unpriced = ProjectUsage(
    id: "-p", displayPath: "/p", name: "p",
    totals: TokenTotals(input: 100, costUSD: nil),
    sessionCount: 1, lastActivity: now, isActive: false
)
unpriced.subAgentTotals = TokenTotals(input: 40, costUSD: nil)
checkEqual(unpriced.mainTotals.input, 60, "unpriced project main input")
check(unpriced.mainTotals.costUSD == nil, "unpriced project keeps nil main cost")

// MARK: - 5. Live data (read-only, skipped when absent)

let liveRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jcode/sessions")
if FileManager.default.fileExists(atPath: liveRoot.path) {
    let urls = (try? FileManager.default.contentsOfDirectory(at: liveRoot, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "json" } ?? []

    var parsedLive: [JcodeLogParser.AccountSessions] = []
    parsedLive.reserveCapacity(urls.count)
    for url in urls {
        if let aggregate = try? JcodeLogParser.parseSession(url, captureTitles: false) {
            parsedLive.append(aggregate)
        }
    }
    let live = JcodeLogParser.attributeToRootProjects(parsedLive)

    var mainTokens: Int64 = 0
    var subTokens: Int64 = 0
    var subSessions = 0
    for aggregate in live {
        for slice in aggregate.byAccount.values {
            let total = slice.entries.reduce(Int64(0)) {
                $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite5m + $1.cacheWrite1h
            }
            if slice.isSubAgent == true { subTokens += total } else { mainTokens += total }
        }
        if aggregate.parentID != nil { subSessions += 1 }
    }

    let all = mainTokens + subTokens
    let share = all > 0 ? Double(subTokens) / Double(all) * 100 : 0
    print(String(
        format: "live: %d files, %d sub-agent sessions, sub-agent share %.1f%%",
        urls.count, subSessions, share
    ))
    if subSessions > 0 {
        check(subTokens > 0, "live sub-agent sessions carry tokens")
    }
} else {
    print("live: ~/.jcode/sessions absent, skipped")
}

// MARK: - Result

if failures.isEmpty {
    print("ALL PASS")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
