import Foundation

/// Claude usage: live rate-limit windows from the OAuth usage endpoint (the
/// same one Claude Code's `/usage` calls) plus exact token/cost history from
/// the local project logs.
///
/// One instance per Claude Code **account** (`ClaudeAccount`). Each account has
/// its own config dir, log tree, parse cache and Keychain item, so two accounts
/// can never read each other's numbers.
actor ClaudeProvider: UsageProvider, ProjectBreakdownProviding {
    nonisolated let id: ProviderID
    nonisolated let descriptor: ProviderDescriptor

    private let api: ClaudeUsageAPI
    private let credentialsStore: ClaudeCredentialsStore
    private let parser: ClaudeLogParser

    init(
        account: ClaudeAccount,
        http: HTTPClient = HTTPClient(),
        credentialsStore: ClaudeCredentialsStore? = nil,
        parser: ClaudeLogParser? = nil,
        captureTitles: Bool = true
    ) {
        self.id = account.id
        self.descriptor = ProviderDescriptor(
            id: account.id,
            name: account.name,
            shortCode: account.shortCode,
            appBundleID: "com.anthropic.claudefordesktop",
            webURL: URL(string: "https://claude.ai")!,
            setupHint: "Sign in to Claude Code (\(account.configDir.lastPathComponent)) to start tracking."
        )
        self.api = ClaudeUsageAPI(http: http)
        self.credentialsStore = credentialsStore ?? ClaudeCredentialsStore(
            fileURL: account.credentialsFile,
            keychainService: account.keychainService
        )
        // The primary account keeps the historical cache names, so upgrading
        // doesn't force a full re-parse of thousands of session files.
        self.parser = parser ?? ClaudeLogParser(
            projectsRoot: account.projectsRoot,
            captureTitles: captureTitles,
            cacheName: account.id == .claude
                ? nil
                : "\(account.cacheNamespace)-files-v2\(captureTitles ? "" : "-blind")"
        )
    }

    func probeConnection() async -> ProviderConnection {
        await credentialsStore.sourceExists()
            ? .available
            : .notConnected(hint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        let now = Date.now
        async let reportTask = parser.report(now: now)
        let limits = await loadLimits()
        let report = await reportTask

        var snapshot = UsageSnapshot(providerID: id, fetchedAt: now)
        snapshot.plan = limits.plan

        var limitsError: ProviderFetchError?
        switch limits.windows {
        case .success(let response):
            let mapped = ClaudeUsageAPI.limitWindows(from: response)
            snapshot.primary = mapped.primary
            snapshot.secondary = mapped.secondary
            snapshot.tertiary = mapped.tertiary
            snapshot.extraWindows = mapped.extras
        case .failure(let error):
            limitsError = error
            snapshot.limitsUnavailable = true
            snapshot.statusNotes.append("Limits unavailable: \(error.userMessage)")
        }

        var logsError: ProviderFetchError?
        if let tokens = report.tokens {
            snapshot.tokens = tokens
            snapshot.dailyUsage = report.dailyUsage
            snapshot.histograms = report.histograms
        } else {
            logsError = .dataUnavailable(description: "No recent Claude Code session logs")
            snapshot.statusNotes.append("Token history unavailable: no recent session logs")
        }

        // One healthy source still makes a useful snapshot; both failing is a
        // fetch failure, surfaced as whichever error is more actionable.
        if let limitsError, let logsError {
            throw Self.moreInformative(limitsError, logsError)
        }
        return snapshot
    }

    // MARK: - Project / session breakdown

    /// Per-project/session usage from the local logs, reusing the same warm
    /// cache `fetch()` fills. Costs are shown (computed from the pricing table).
    func projectBreakdown(timeframe: BreakdownTimeframe, now: Date = .now) async -> ProjectBreakdown? {
        let projects = await parser.breakdown(timeframe: timeframe, now: now)
        guard !projects.isEmpty else { return nil }
        let grandTotal = projects.reduce(into: TokenTotals()) { $0.add($1.totals) }
        return ProjectBreakdown(
            providerID: id,
            timeframe: timeframe,
            generatedAt: now,
            projects: projects,
            grandTotal: grandTotal,
            showsCost: true
        )
    }

    // MARK: - Live limits

    private struct Limits: Sendable {
        var plan: String?
        var windows: Result<ClaudeUsageResponse, ProviderFetchError>
    }

    /// Loads credentials (5-minute in-actor cache) and calls the usage
    /// endpoint. On 401 the cache is invalidated and the call retried once
    /// with freshly read credentials — Claude Code may have rotated the token
    /// since the cache filled; Pulse never refreshes tokens itself. A 401
    /// with an unchanged token stays `.unauthorized`.
    private func loadLimits() async -> Limits {
        let credentials: ClaudeCredentials
        do {
            credentials = try await credentialsStore.credentials()
        } catch {
            return Limits(plan: nil, windows: .failure(Self.asFetchError(error)))
        }

        do {
            let response = try await api.fetchUsage(accessToken: credentials.accessToken)
            return Limits(plan: credentials.planLabel, windows: .success(response))
        } catch ProviderFetchError.unauthorized {
            await credentialsStore.invalidate()
            do {
                let fresh = try await credentialsStore.credentials(forceReload: true)
                guard fresh.accessToken != credentials.accessToken else {
                    return Limits(plan: fresh.planLabel, windows: .failure(.unauthorized))
                }
                let response = try await api.fetchUsage(accessToken: fresh.accessToken)
                return Limits(plan: fresh.planLabel, windows: .success(response))
            } catch {
                return Limits(plan: credentials.planLabel, windows: .failure(Self.asFetchError(error)))
            }
        } catch {
            return Limits(plan: credentials.planLabel, windows: .failure(Self.asFetchError(error)))
        }
    }

    // MARK: - Error shaping

    /// Everything leaving the provider is a `ProviderFetchError`; messages
    /// never carry token material.
    private static func asFetchError(_ error: any Error) -> ProviderFetchError {
        error as? ProviderFetchError ?? .parsing(description: "Claude: unexpected \(type(of: error))")
    }

    /// Auth problems are actionable, parse failures point at real bugs, and
    /// transport blips beat "no data yet" — pick the louder of the two.
    private static func moreInformative(
        _ lhs: ProviderFetchError,
        _ rhs: ProviderFetchError
    ) -> ProviderFetchError {
        func rank(_ error: ProviderFetchError) -> Int {
            switch error {
            case .unauthorized: 5
            case .notLoggedIn: 4
            case .parsing: 3
            case .http: 2
            case .network: 1
            case .dataUnavailable: 0
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }
}
