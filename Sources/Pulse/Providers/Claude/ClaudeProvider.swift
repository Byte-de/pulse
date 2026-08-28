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
    private let jcodeAccountLabel: String?
    /// jcode's credential store, used only as a fallback when Claude Code's
    /// token is expired. nil when the account has no jcode identity.
    private let jcodeCredentialsStore: JcodeCredentialsStore?

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
        self.jcodeAccountLabel = account.jcodeAccountLabel
        self.jcodeCredentialsStore = account.jcodeAccountLabel == nil
            ? nil
            : JcodeCredentialsStore()
    }

    /// This account's credentials as jcode holds them, if any.
    private func jcodeCredentials() -> ClaudeCredentials? {
        guard let jcodeCredentialsStore, let jcodeAccountLabel else { return nil }
        return jcodeCredentialsStore.credentials(forAccountLabel: jcodeAccountLabel)
    }

    func probeConnection() async -> ProviderConnection {
        if await credentialsStore.sourceExists() { return .available }
        // An account signed in through jcode but never through Claude Code has
        // no Keychain item, and would otherwise render as "not connected"
        // despite having live credentials and parseable logs.
        if jcodeCredentials() != nil { return .available }
        return .notConnected(hint: descriptor.setupHint)
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
        var credentials: ClaudeCredentials
        do {
            credentials = try await credentialsStore.credentials()
        } catch {
            // Claude Code has no usable token. jcode may still hold a live one
            // for the same account, so a hard failure here is premature.
            if let fallback = jcodeCredentials(), !fallback.isExpired() {
                credentials = fallback
            } else {
                return Limits(plan: nil, windows: .failure(Self.asFetchError(error)))
            }
        }

        // Claude Code only refreshes when Claude Code runs, so its token is
        // routinely hours stale while jcode's copy of the same account is
        // current. Prefer whichever store actually holds a valid token rather
        // than a fixed order: sending the expired one wastes a request and,
        // repeated every refresh tick, gets the endpoint to rate-limit the
        // account (observed 2026-08-28, HTTP 429 with Retry-After 2808).
        if credentials.isExpired(), let fallback = jcodeCredentials(), !fallback.isExpired() {
            credentials = ClaudeCredentials(
                accessToken: fallback.accessToken,
                expiresAt: fallback.expiresAt,
                // jcode records no plan, so keep the Keychain's label: the
                // token is stale but the plan it names is not.
                subscriptionType: credentials.subscriptionType,
                rateLimitTier: credentials.rateLimitTier
            )
        }

        do {
            let response = try await api.fetchUsage(accessToken: credentials.accessToken)
            return Limits(plan: credentials.planLabel, windows: .success(response))
        } catch ProviderFetchError.unauthorized {
            await credentialsStore.invalidate()
            do {
                let fresh = try await credentialsStore.credentials(forceReload: true)
                guard fresh.accessToken != credentials.accessToken else {
                    // Claude Code's token is unchanged and rejected. jcode is
                    // the only remaining chance at a live token.
                    if let fallback = jcodeCredentials(),
                       !fallback.isExpired(),
                       fallback.accessToken != credentials.accessToken {
                        let response = try await api.fetchUsage(accessToken: fallback.accessToken)
                        return Limits(plan: fresh.planLabel, windows: .success(response))
                    }
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
