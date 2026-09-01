import Foundation

/// Byte-branded mock breakdown for `--demo-data` (screenshots and demos). It is
/// activated only by the launch flag and never used in normal operation. The
/// same dataset is mirrored in the website's interactive demo so the marketing
/// page and the real app show identical numbers.
struct DemoBreakdownProvider: ProjectBreakdownProviding {
    let id: ProviderID

    /// The demo dataset has one fixed shape, so the source filter is accepted
    /// and ignored: screenshots must look the same however the switches sit.
    func projectBreakdown(
        timeframe: BreakdownTimeframe,
        sources: UsageSourceSelection,
        now: Date
    ) async -> ProjectBreakdown? {
        DemoBreakdownData.breakdown(for: id, timeframe: timeframe, now: now)
    }

    /// The breakdown-capable demo providers (Claude with cost, Codex without).
    static let all: [any ProjectBreakdownProviding] = [
        DemoBreakdownProvider(id: .claude),
        DemoBreakdownProvider(id: .codex),
    ]
}

/// Builds the canonical Byte demo dataset. Numbers are plausible but fixed;
/// timestamps are relative to `now` so "Active now" and "2h ago" render live.
enum DemoBreakdownData {
    static func breakdown(for id: ProviderID, timeframe: BreakdownTimeframe, now: Date) -> ProjectBreakdown? {
        switch id {
        case .claude: claude(timeframe: timeframe, now: now)
        case .codex: codex(timeframe: timeframe, now: now)
        default: nil
        }
    }

    // MARK: - Claude (costs shown, CLI-generated titles)

    private static func claude(timeframe: BreakdownTimeframe, now: Date) -> ProjectBreakdown {
        var aggregator = ProjectUsageAggregator()
        addProject(&aggregator, "byte-pulse", sessions: [
            claudeSession("Add per-project usage breakdown", "opus-4.8", 4_200_000, 18.40, minutesAgo: 1.5, branch: "feature/breakdown", now: now),
            claudeSession("Light-mode contrast pass", "sonnet-4.6", 2_300_000, 6.90, minutesAgo: 120, branch: "main", now: now),
            claudeSession("Menu-bar icon redesign", "opus-4.8", 1_650_000, 7.20, minutesAgo: 360, branch: "main", now: now),
            claudeSession("Codex rate-limit fallback", "sonnet-4.6", 1_100_000, 3.40, minutesAgo: 1560, branch: "main", now: now),
        ])
        addProject(&aggregator, "pulse-website", sessions: [
            claudeSession("Interactive panel demo", "sonnet-4.6", 2_050_000, 6.10, minutesAgo: 180, branch: "main", now: now),
            claudeSession("German locale + legal pages", "sonnet-4.6", 1_400_000, 4.20, minutesAgo: 1680, branch: "main", now: now),
            claudeSession("Hero motion polish", "haiku-4.5", 720_000, 0.80, minutesAgo: 2880, branch: "main", now: now),
        ])
        addProject(&aggregator, "byte-ui", sessions: [
            claudeSession("Concentric-radius card primitives", "opus-4.8", 1_500_000, 6.80, minutesAgo: 480, branch: "main", now: now),
            claudeSession("Liquid-glass tokens", "opus-4.8", 980_000, 4.10, minutesAgo: 1800, branch: "main", now: now),
            claudeSession("Icon set audit", "haiku-4.5", 540_000, 0.60, minutesAgo: 4320, branch: "main", now: now),
        ])
        addProject(&aggregator, "byte-api", sessions: [
            claudeSession("Usage aggregation endpoints", "sonnet-4.6", 1_300_000, 3.90, minutesAgo: 300, branch: "main", now: now),
            claudeSession("Rate-limit middleware", "sonnet-4.6", 760_000, 2.30, minutesAgo: 2880, branch: "main", now: now),
        ])
        addProject(&aggregator, "byte-cli", sessions: [
            claudeSession("Token-count subcommand", "haiku-4.5", 430_000, 0.50, minutesAgo: 5760, branch: "main", now: now),
            claudeSession("Shell completions", "haiku-4.5", 210_000, 0.20, minutesAgo: 8640, branch: "main", now: now),
        ])
        return assemble(.claude, aggregator, timeframe: timeframe, now: now, showsCost: true)
    }

    // MARK: - Codex (tokens only, no titles — mirrors the real source)

    private static func codex(timeframe: BreakdownTimeframe, now: Date) -> ProjectBreakdown {
        var aggregator = ProjectUsageAggregator()
        addProject(&aggregator, "byte-pulse", sessions: [
            codexSession("019eabc4-7764-7091-a4be-8ef3ab07f760", 3_100_000, minutesAgo: 240, branch: "main", now: now),
            codexSession("019eb1d2-0e9c-7833-87f7-85d43836e329", 1_900_000, minutesAgo: 1620, branch: "main", now: now),
        ])
        addProject(&aggregator, "byte-api", sessions: [
            codexSession("019ea77f-3c41-7a52-9b0e-1d77c0e3a8b2", 2_400_000, minutesAgo: 420, branch: "main", now: now),
            codexSession("019e9c10-8b22-70d4-aa31-4f6e2b9c5d17", 1_050_000, minutesAgo: 2880, branch: "main", now: now),
        ])
        addProject(&aggregator, "pulse-website", sessions: [
            codexSession("019eb930-2a18-71c6-8e44-7c9a0f1b3e6d", 1_350_000, minutesAgo: 1800, branch: "main", now: now),
        ])
        return assemble(.codex, aggregator, timeframe: timeframe, now: now, showsCost: false)
    }

    // MARK: - Builders

    private static func addProject(_ aggregator: inout ProjectUsageAggregator, _ name: String, sessions: [SessionUsage]) {
        for session in sessions {
            aggregator.add(session, projectKey: "demo:\(name)", displayPath: "~/Code/\(name)", name: name)
        }
    }

    private static func assemble(
        _ id: ProviderID,
        _ aggregator: ProjectUsageAggregator,
        timeframe: BreakdownTimeframe,
        now: Date,
        showsCost: Bool
    ) -> ProjectBreakdown {
        let projects = aggregator.projects()
        let grandTotal = projects.reduce(into: TokenTotals()) { $0.add($1.totals) }
        return ProjectBreakdown(
            providerID: id,
            timeframe: timeframe,
            generatedAt: now,
            projects: projects,
            grandTotal: grandTotal,
            showsCost: showsCost
        )
    }

    private static func claudeSession(
        _ title: String, _ model: String, _ total: Int64, _ cost: Double,
        minutesAgo: Double, branch: String, now: Date
    ) -> SessionUsage {
        let totals = shape(total, cost: cost, isClaude: true)
        let last = now.addingTimeInterval(-minutesAgo * 60)
        return SessionUsage(
            id: "demo-" + slug(title),
            title: title,
            gitBranch: branch,
            totals: totals,
            startedAt: last.addingTimeInterval(-90 * 60),
            lastActivity: last,
            isActive: minutesAgo < 5,
            modelBreakdown: [ModelShare(model: model, share: 100, totals: totals)]
        )
    }

    private static func codexSession(
        _ id: String, _ total: Int64, minutesAgo: Double, branch: String, now: Date
    ) -> SessionUsage {
        let totals = shape(total, cost: nil, isClaude: false)
        let last = now.addingTimeInterval(-minutesAgo * 60)
        return SessionUsage(
            id: id,
            title: nil,
            gitBranch: branch,
            totals: totals,
            startedAt: last.addingTimeInterval(-60 * 60),
            lastActivity: last,
            isActive: minutesAgo < 5,
            modelBreakdown: [ModelShare(model: "gpt-5-codex", share: 100, totals: totals)]
        )
    }

    /// Splits a token total into a realistic cache-heavy shape. Claude carries
    /// cache writes + a cost; Codex (plan-included) folds cache into reads only.
    private static func shape(_ total: Int64, cost: Double?, isClaude: Bool) -> TokenTotals {
        if isClaude {
            return TokenTotals(
                input: total * 12 / 100,
                output: total * 6 / 100,
                cacheRead: total * 76 / 100,
                cacheWrite: total * 6 / 100,
                costUSD: cost
            )
        }
        return TokenTotals(
            input: total * 22 / 100,
            output: total * 8 / 100,
            cacheRead: total * 70 / 100,
            cacheWrite: 0,
            costUSD: nil
        )
    }

    private static func slug(_ string: String) -> String {
        string.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
