import Foundation

/// GitHub Copilot premium-request quota via `copilot_internal/user` — the
/// same RPC the official editor plugins call (docs/RESEARCH/oss-reference.md
/// §D). Quota-only by design: GitHub exposes no token/cost ledger, so
/// `tokens`/`dailyUsage` stay empty and the tab shows the monthly premium
/// allowance plus any metered chat/completions lanes.
actor CopilotProvider: UsageProvider {
    private static let setupHintText = "Sign in to GitHub Copilot in your editor to start tracking."
    static let tokenExpiredHint = "GitHub token expired — sign in to Copilot again in your editor."

    nonisolated let id: ProviderID = .copilot
    nonisolated let descriptor = ProviderDescriptor(
        id: .copilot,
        name: "Copilot",
        shortCode: "COP",
        appBundleID: nil,
        webURL: URL(string: "https://github.com/settings/copilot")!,
        setupHint: CopilotProvider.setupHintText
    )

    private let root: URL
    private let api: CopilotAPI

    init(root: URL = CopilotAuth.defaultRoot, http: HTTPClient = HTTPClient()) {
        self.root = root
        self.api = CopilotAPI(http: http)
    }

    func probeConnection() async -> ProviderConnection {
        CopilotAuth.probe(root: root, setupHint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        guard let credentials = CopilotAuth.load(root: root),
              let token = credentials.oauthToken, !token.isEmpty
        else {
            throw ProviderFetchError.notLoggedIn(hint: descriptor.setupHint)
        }

        let response: CopilotAPI.UsageResponse
        do {
            response = try await api.fetchUsage(token: token)
        } catch ProviderFetchError.unauthorized {
            // 401/403 from GitHub: the long-lived oauth token was revoked or
            // expired — only re-authenticating in the editor mints a new one.
            throw ProviderFetchError.notLoggedIn(hint: Self.tokenExpiredHint)
        }

        return Self.makeSnapshot(response: response, credentials: credentials)
    }

    // MARK: - Snapshot assembly (pure, tested)

    static func makeSnapshot(
        response: CopilotAPI.UsageResponse,
        credentials: CopilotAuth.Credentials,
        calendar: Calendar = .current
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot(providerID: .copilot)
        snapshot.plan = CopilotAPI.planLabel(response.copilotPlan)
        snapshot.accountLabel = credentials.user.flatMap(CopilotAuth.maskedUser)

        let resetsAt = response.quotaResetDate.flatMap {
            CopilotAPI.parseResetDate($0, calendar: calendar)
        }

        // Premium requests: the headline gauge (monthly allowance).
        if let premium = response.premiumInteractions, premium.unlimited == true {
            snapshot.statusNotes.append("Premium requests: unlimited")
        } else if let premium = response.premiumInteractions,
                  let utilization = CopilotAPI.utilization(of: premium) {
            snapshot.primary = LimitWindow(
                id: "premium",
                title: "Premium Requests",
                systemImage: "calendar",
                utilization: utilization,
                resetsAt: resetsAt,
                detail: CopilotAPI.detail(for: premium)
            )
        } else {
            snapshot.statusNotes.append("No premium request quota reported")
        }

        // Metered chat/completions lanes; unlimited (the common case on paid
        // plans) carries no gauge signal and is dropped.
        let extras: [(id: String, title: String, snapshot: CopilotAPI.QuotaSnapshot?)] = [
            ("chat", "Chat", response.chat),
            ("completions", "Completions", response.completions),
        ]
        for extra in extras {
            guard let quota = extra.snapshot, quota.unlimited != true,
                  let utilization = CopilotAPI.utilization(of: quota)
            else { continue }
            snapshot.extraWindows.append(LimitWindow(
                id: extra.id,
                title: extra.title,
                systemImage: "sparkles",
                utilization: utilization,
                resetsAt: resetsAt,
                detail: CopilotAPI.detail(for: quota)
            ))
        }

        return snapshot
    }
}
