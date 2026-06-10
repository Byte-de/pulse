import Foundation

/// Gemini CLI quota via the Google Code Assist private API — the same RPCs
/// the CLI's `/stats` uses (docs/RESEARCH/gemini.md). Quota-only by design:
/// Gemini exposes no token/cost ledger, so `tokens`/`dailyUsage` stay empty
/// and the tab shows per-model daily quotas, tier, and account.
actor GeminiProvider: UsageProvider {
    private static let setupHintText = "Run `gemini` and sign in with Google to start tracking."

    nonisolated let id: ProviderID = .gemini
    nonisolated let descriptor = ProviderDescriptor(
        id: .gemini,
        name: "Gemini",
        shortCode: "GEM",
        appBundleID: nil,
        webURL: URL(string: "https://gemini.google.com")!,
        setupHint: GeminiProvider.setupHintText
    )

    private let root: URL
    private let auth: GeminiAuth
    private let api: GeminiQuotaAPI

    init(
        root: URL = AppPaths.home.appendingPathComponent(".gemini", isDirectory: true),
        transport: any GeminiTransport = GeminiURLSessionTransport()
    ) {
        self.root = root
        self.auth = GeminiAuth(root: root, transport: transport, setupHint: GeminiProvider.setupHintText)
        self.api = GeminiQuotaAPI(transport: transport)
    }

    func probeConnection() async -> ProviderConnection {
        GeminiAuth.probe(root: root, setupHint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        do {
            return try await fetchOnce()
        } catch ProviderFetchError.unauthorized {
            // Token revoked before its expiry: drop the in-memory token and
            // retry once with a fresh refresh-token round-trip.
            await auth.invalidate()
            return try await fetchOnce()
        }
    }

    private func fetchOnce() async throws -> UsageSnapshot {
        let token = try await auth.accessToken()
        let assist = try await api.loadCodeAssist(token: token)
        let claims = await auth.idTokenClaims()

        var snapshot = UsageSnapshot(providerID: .gemini)
        snapshot.plan = GeminiQuotaAPI.tierLabel(id: assist.tierID, isWorkspace: claims.isWorkspace)
        snapshot.accountLabel = await auth.accountLabel()

        guard let project = assist.project else {
            // Free-tier projects are provisioned lazily on first CLI use.
            snapshot.statusNotes.append("No project provisioned yet — run a Gemini prompt first")
            return snapshot
        }

        let buckets = try await api.retrieveUserQuota(token: token, project: project)
        var windows = GeminiQuotaAPI.quotaWindows(from: buckets)

        guard !windows.isEmpty else {
            snapshot.statusNotes.append("No quota data yet")
            return snapshot
        }

        // Worst (highest-utilization) model becomes the headline gauge; the
        // remaining models render as compact rows underneath.
        let worst = windows.removeFirst()
        snapshot.primary = LimitWindow(
            id: "quota",
            title: "Daily Quota",
            systemImage: "gauge",
            utilization: worst.utilization,
            resetsAt: worst.resetsAt,
            windowDuration: worst.windowDuration,
            detail: worst.title
        )
        snapshot.extraWindows = windows
        return snapshot
    }
}
