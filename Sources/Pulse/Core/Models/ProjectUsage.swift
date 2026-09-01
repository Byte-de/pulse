import Foundation

/// Time horizon of the project/session breakdown window.
///
/// Distinct from `UsageTimeframe` (the panel histogram's frames): the breakdown
/// filters whole sessions over a trailing range rather than bucketing one
/// series, so it speaks in ranges ("last 7 days") not bar granularities.
/// `lastYear` is the practical ceiling — the local-log parsers only scan ~366
/// days of files, so nothing older is available to attribute anyway.
enum BreakdownTimeframe: String, CaseIterable, Codable, Sendable, Identifiable {
    case last7Days
    case last30Days
    case lastYear

    var id: String { rawValue }

    /// Badge label, cycling order = `allCases` order.
    var label: String {
        switch self {
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .lastYear: "1 year"
        }
    }

    /// Number of trailing calendar days the frame includes (today inclusive).
    var days: Int {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .lastYear: 366
        }
    }
}

/// Sort order for the projects list in the breakdown window.
enum BreakdownSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case tokens
    case cost
    case recent
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: "Cost"
        case .recent: "Recent"
        case .name: "Name"
        }
    }

    /// Orders projects for display. `cost` falls back to tokens when a project
    /// carries no cost (so Codex / unknown-model rows still order sensibly).
    func sorted(_ projects: [ProjectUsage]) -> [ProjectUsage] {
        switch self {
        case .tokens:
            projects.sorted { $0.totals.total > $1.totals.total }
        case .cost:
            projects.sorted { ($0.totals.costUSD ?? -1) > ($1.totals.costUSD ?? -1) }
        case .recent:
            projects.sorted { $0.lastActivity > $1.lastActivity }
        case .name:
            projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

/// Usage rolled up for one **session/thread** — a single CLI run (one
/// `~/.claude/projects/**/<id>.jsonl` or one `~/.codex/sessions/**/rollout-*.jsonl`).
/// This is the "which instance" unit the breakdown is built around.
struct SessionUsage: Sendable, Equatable, Identifiable {
    /// Stable session id (the log file's UUID). Globally unique, so it also
    /// serves as the `ForEach` id in a flat session list.
    let id: String
    /// Friendly title when the CLI recorded one (Claude's `ai-title`); `nil`
    /// in content-blind mode or for sources that don't generate titles (Codex).
    /// The view composes a fallback from `gitBranch` + `startedAt` when nil.
    var title: String?
    /// Git branch at the session's most recent activity, when the log carries it.
    var gitBranch: String?
    var totals: TokenTotals
    /// First and last observed activity for this session (full timestamps, so
    /// the "Active now" signal can be minute-accurate, not day-bucketed).
    var startedAt: Date?
    var lastActivity: Date
    /// True when `lastActivity` is within the live threshold of "now".
    var isActive: Bool
    /// Per-model split of this session's tokens, sorted descending by share.
    var modelBreakdown: [ModelShare] = []
    /// True when this session was spawned by another session (jcode writes a
    /// `parent_id`). Sub-agent-ness is a property of the *session*, at any
    /// nesting depth: a child of a child is still sub-agent work.
    var isSubAgent: Bool = false
}

/// Usage rolled up for one **project** — a working directory, the natural
/// grouping above sessions. Sessions are attributed to a project by their `cwd`
/// (Claude/Codex both record it); Claude additionally keys on the stable
/// encoded project-directory name so attribution survives a missing `cwd`.
struct ProjectUsage: Sendable, Equatable, Identifiable {
    /// Stable grouping key, unique within one provider's breakdown.
    let id: String
    /// Home-abbreviated path for display, e.g. "~/Programmieren/usage-tracker".
    var displayPath: String
    /// Last path component, e.g. "usage-tracker".
    var name: String
    /// Sum of this project's sessions over the selected timeframe.
    var totals: TokenTotals
    var sessionCount: Int
    var lastActivity: Date
    /// True when any of the project's sessions is currently active.
    var isActive: Bool
    /// Member sessions, sorted descending by token total.
    var sessions: [SessionUsage] = []
    /// The slice of `totals` contributed by sub-agent sessions. A **subset** of
    /// `totals`, never an addition: `totals` already includes it. The
    /// main-session-only figure is `mainTotals`, so no caller has to remember
    /// the direction of the subtraction.
    var subAgentTotals: TokenTotals = .zero
    /// Number of member sessions that are sub-agent runs.
    var subAgentSessionCount: Int = 0

    /// Main-session usage only: everything not attributed to a sub-agent.
    var mainTotals: TokenTotals {
        TokenTotals(
            input: totals.input - subAgentTotals.input,
            output: totals.output - subAgentTotals.output,
            cacheRead: totals.cacheRead - subAgentTotals.cacheRead,
            cacheWrite: totals.cacheWrite - subAgentTotals.cacheWrite,
            // nil cost stays nil: a project with no priced model must not
            // report $0 main cost just because the subtraction is trivial.
            costUSD: totals.costUSD.map { $0 - (subAgentTotals.costUSD ?? 0) }
        )
    }

    var hasSubAgentUsage: Bool { subAgentTotals.total > 0 }
}

/// One provider's complete breakdown for a timeframe — the value the breakdown
/// window renders. Capability-shaped like `UsageSnapshot`: providers that can't
/// attribute by project simply never produce one.
struct ProjectBreakdown: Sendable, Equatable, Identifiable {
    let providerID: ProviderID
    let timeframe: BreakdownTimeframe
    let generatedAt: Date
    /// Projects sorted descending by token total.
    var projects: [ProjectUsage]
    var grandTotal: TokenTotals
    /// Whether a Cost column is meaningful (false for plan-included Codex usage).
    var showsCost: Bool

    var id: ProviderID { providerID }
    var isEmpty: Bool { projects.isEmpty }
    var sessionCount: Int { projects.reduce(0) { $0 + $1.sessionCount } }

    /// Sub-agent slice of `grandTotal` (a subset of it, see
    /// `ProjectUsage.subAgentTotals`).
    var subAgentTotal: TokenTotals {
        projects.reduce(into: TokenTotals()) { $0.add($1.subAgentTotals) }
    }

    /// True when any project carries sub-agent usage — the gate for the
    /// sub-agent columns, so providers that can't see sub-agents (Claude Code,
    /// Codex) keep the narrow table rather than a column of zeros.
    var showsSubAgents: Bool { projects.contains(where: \.hasSubAgentUsage) }

    /// A copy with every session title cleared — used to honor the content-blind
    /// setting immediately in the UI, even before a relaunch re-parses without
    /// titles. Pure data transform; the view composes a path/branch fallback.
    func hidingSessionTitles() -> ProjectBreakdown {
        var copy = self
        copy.projects = projects.map { project in
            var project = project
            project.sessions = project.sessions.map { session in
                var session = session
                session.title = nil
                return session
            }
            return project
        }
        return copy
    }
}

/// Accumulates `SessionUsage` values into `ProjectUsage` groups, shared by the
/// breakdown-capable parsers so the grouping + sort logic lives in one place.
struct ProjectUsageAggregator {
    private var byProject: [String: ProjectUsage] = [:]

    /// Adds a session to its project, creating the project on first sight.
    /// `displayPath`/`name` are evaluated only when the project is new.
    mutating func add(
        _ session: SessionUsage,
        projectKey: String,
        displayPath: @autoclosure () -> String,
        name: @autoclosure () -> String
    ) {
        if var project = byProject[projectKey] {
            project.totals.add(session.totals)
            project.sessionCount += 1
            project.sessions.append(session)
            project.lastActivity = max(project.lastActivity, session.lastActivity)
            project.isActive = project.isActive || session.isActive
            if session.isSubAgent {
                project.subAgentTotals.add(session.totals)
                project.subAgentSessionCount += 1
            }
            byProject[projectKey] = project
        } else {
            byProject[projectKey] = ProjectUsage(
                id: projectKey,
                displayPath: displayPath(),
                name: name(),
                totals: session.totals,
                sessionCount: 1,
                lastActivity: session.lastActivity,
                isActive: session.isActive,
                sessions: [session],
                subAgentTotals: session.isSubAgent ? session.totals : .zero,
                subAgentSessionCount: session.isSubAgent ? 1 : 0
            )
        }
    }

    /// Projects sorted by token total descending, each with its sessions sorted
    /// likewise — the canonical breakdown order.
    func projects() -> [ProjectUsage] {
        byProject.values
            .map { project in
                var project = project
                project.sessions.sort { $0.totals.total > $1.totals.total }
                return project
            }
            .sorted { $0.totals.total > $1.totals.total }
    }
}

/// Derives the project's display strings from a recorded working directory,
/// shared by every breakdown-capable parser so the formatting can't fork.
enum ProjectDisplay {
    /// Last path component of `cwd`, falling back to `fallback` (e.g. the
    /// encoded project key) when no working directory was recorded.
    static func name(cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        let component = URL(fileURLWithPath: cwd).lastPathComponent
        return component.isEmpty ? fallback : component
    }

    /// Home-abbreviated `cwd` for display, falling back to `fallback` when no
    /// working directory was recorded.
    static func displayPath(cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        return AppPaths.abbreviatingHome(cwd)
    }
}
