import Foundation

/// Claude usage: live rate-limit windows from the OAuth usage endpoint (the
/// same one Claude Code's `/usage` calls) plus exact token/cost history from
/// the local project logs.
actor ClaudeProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    nonisolated let descriptor = ProviderDescriptor(
        id: .claude,
        name: "Claude",
        shortCode: "CLA",
        appBundleID: "com.anthropic.claudefordesktop",
        webURL: URL(string: "https://claude.ai")!,
        setupHint: "Sign in to Claude Code to start tracking."
    )

    private let api: ClaudeUsageAPI
    private let credentialsStore: ClaudeCredentialsStore
    private let parser: ClaudeLogParser

    init(
        http: HTTPClient = HTTPClient(),
        credentialsStore: ClaudeCredentialsStore = ClaudeCredentialsStore(),
        parser: ClaudeLogParser = ClaudeLogParser()
    ) {
        self.api = ClaudeUsageAPI(http: http)
        self.credentialsStore = credentialsStore
        self.parser = parser
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

        var snapshot = UsageSnapshot(providerID: .claude, fetchedAt: now)
        snapshot.plan = limits.plan

        var limitsError: ProviderFetchError?
        switch limits.windows {
        case .success(let response):
            let mapped = ClaudeUsageAPI.limitWindows(from: response)
            snapshot.primary = mapped.primary
            snapshot.secondary = mapped.secondary
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
