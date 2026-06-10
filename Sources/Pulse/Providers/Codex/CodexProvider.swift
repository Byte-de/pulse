import Foundation

/// OpenAI Codex CLI usage: live ChatGPT-account rate limits (wham/usage) with
/// a session-log fallback, plus token history parsed from local session files.
actor CodexProvider: UsageProvider {
    nonisolated let id: ProviderID = .codex
    nonisolated let descriptor = ProviderDescriptor(
        id: .codex,
        name: "Codex",
        shortCode: "CDX",
        appBundleID: "com.openai.chat",
        webURL: URL(string: "https://chatgpt.com/codex")!,
        setupHint: "Sign in to the Codex CLI to start tracking."
    )

    private let api: CodexUsageAPI
    private let parser: CodexSessionParser
    private let authFileURL: URL

    init(
        http: HTTPClient = HTTPClient(),
        authFileURL: URL = CodexAuth.defaultFileURL,
        parser: CodexSessionParser = CodexSessionParser()
    ) {
        self.api = CodexUsageAPI(http: http)
        self.authFileURL = authFileURL
        self.parser = parser
    }

    func probeConnection() async -> ProviderConnection {
        do {
            _ = try CodexAuth.load(from: authFileURL)
            return .available
        } catch let error as ProviderFetchError {
            if case .notLoggedIn(let hint) = error {
                return .notConnected(hint: hint)
            }
            return .available // parse hiccup: let fetch() surface the real error
        } catch {
            return .notConnected(hint: descriptor.setupHint)
        }
    }

    func fetch() async throws -> UsageSnapshot {
        let auth = try CodexAuth.load(from: authFileURL)
        let now = Date.now

        async let reportTask = parser.report(now: now)
        var limitsError: ProviderFetchError?
        var response: CodexUsageResponse?
        do {
            response = try await api.fetchUsage(auth: auth)
        } catch let error as ProviderFetchError {
            limitsError = error
        }
        let report = await reportTask

        var snapshot = UsageSnapshot(providerID: .codex, fetchedAt: now)
        snapshot.plan = auth.plan ?? response?.planType.map(CodexAuth.planDisplayName)
        snapshot.accountLabel = auth.accountLabel
        snapshot.tokens = report.tokens
        snapshot.dailyUsage = report.dailyUsage
        snapshot.histograms = report.histograms

        if let response {
            let windows = CodexUsageAPI.limitWindows(from: response, now: now)
            snapshot.primary = windows.primary
            snapshot.secondary = windows.secondary
            if let credits = CodexUsageAPI.creditsNote(from: response) {
                snapshot.statusNotes.append(credits)
            }
        } else if let fallback = report.newestRateLimits {
            applyFallbackLimits(fallback, to: &snapshot, now: now)
        }

        if snapshot.primary == nil && snapshot.tokens == nil {
            throw limitsError ?? .dataUnavailable(description: "No Codex usage data yet — run a Codex session first.")
        }
        if snapshot.primary == nil {
            snapshot.limitsUnavailable = true
            snapshot.statusNotes.append("No rate-limit data: \(limitsError?.userMessage ?? "unavailable")")
        }
        // A dead token must not hide behind stale session-log gauges.
        switch limitsError {
        case .unauthorized, .notLoggedIn:
            snapshot.statusNotes.append("Codex sign-in expired — run `codex` to refresh")
        default:
            break
        }
        return snapshot
    }

    /// Session-log snapshots use `window_minutes` + epoch-second `resets_at`
    /// and go stale as soon as no session is running. Windows whose reset time
    /// has already passed describe a window that no longer exists — showing
    /// their old utilization (with a perpetual "Resets in: <1m") would be a
    /// lie, so they are dropped.
    private func applyFallbackLimits(
        _ fallback: CodexSessionParser.RateLimitSnapshot,
        to snapshot: inout UsageSnapshot,
        now: Date
    ) {
        func window(
            used: Double?, resetsEpoch: Double?, minutes: Double?,
            build: (Double, Date?, TimeInterval?) -> LimitWindow
        ) -> LimitWindow? {
            guard let used else { return nil }
            let resetsAt = resetsEpoch.map { Date(timeIntervalSince1970: $0) }
            if let resetsAt, resetsAt <= now { return nil } // window already rolled over
            return build(used, resetsAt, minutes.map { $0 * 60 })
        }

        snapshot.primary = window(
            used: fallback.primaryUsedPercent,
            resetsEpoch: fallback.primaryResetsAtEpoch,
            minutes: fallback.primaryWindowMinutes,
            build: CodexLimitWindows.fiveHour
        )
        snapshot.secondary = window(
            used: fallback.secondaryUsedPercent,
            resetsEpoch: fallback.secondaryResetsAtEpoch,
            minutes: fallback.secondaryWindowMinutes,
            build: CodexLimitWindows.weekly
        )

        if snapshot.primary != nil, now.timeIntervalSince(fallback.date) > 600 {
            snapshot.statusNotes.append(
                "Limits from last session (\(Formatters.relativeAge(of: fallback.date, now: now)))"
            )
        }
    }
}
