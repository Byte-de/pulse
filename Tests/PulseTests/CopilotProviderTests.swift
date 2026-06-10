import Foundation
import Testing
@testable import Pulse

// MARK: - Test helpers

/// Runs `body` against a throwaway ~/.config/github-copilot-style root.
private func withCopilotRoot(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pulse-copilot-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func write(_ json: String, to root: URL, file: String) throws {
    try Data(json.utf8).write(to: root.appendingPathComponent(file))
}

/// Fabricated fixtures — fake tokens, never real credentials.
private let appsJSON = #"""
{"github.com:Iv1.b507a08c87ecfe98":{"user":"octocat","oauth_token":"gho_FAKEFAKEFAKE","githubAppId":"Iv1.b507a08c87ecfe98"}}
"""#
private let hostsJSON = #"""
{"github.com":{"user":"hubber","oauth_token":"ghu_LEGACYFAKE"}}
"""#

// MARK: - Auth file parsing

@Suite("CopilotCredentials")
struct CopilotCredentialsTests {
    @Test func parsesAppsFile() {
        let creds = CopilotAuth.parseApps(Data(appsJSON.utf8))
        #expect(creds == CopilotAuth.Credentials(oauthToken: "gho_FAKEFAKEFAKE", user: "octocat"))
    }

    @Test func parsesLegacyHostsFile() {
        let creds = CopilotAuth.parseHosts(Data(hostsJSON.utf8))
        #expect(creds == CopilotAuth.Credentials(oauthToken: "ghu_LEGACYFAKE", user: "hubber"))
    }

    @Test func skipsNonGitHubHostsAndPrefersUsableEntry() {
        // Enterprise hosts are not github.com; an empty-token github entry
        // loses to a usable one regardless of key order.
        let json = #"""
        {"octocorp.ghe.com:Iv1.abc":{"user":"corp","oauth_token":"gho_ENTERPRISE"},
         "github.com:Iv1.aaa":{"user":"stale","oauth_token":""},
         "github.com:Iv1.bbb":{"user":"fresh","oauth_token":"gho_GOOD"}}
        """#
        let creds = CopilotAuth.parseApps(Data(json.utf8))
        #expect(creds?.oauthToken == "gho_GOOD")
        #expect(creds?.user == "fresh")
    }

    @Test func keepsTokenlessGitHubEntryAsFallback() {
        let creds = CopilotAuth.parseApps(Data(#"{"github.com:Iv1.x":{"user":"octocat"}}"#.utf8))
        #expect(creds == CopilotAuth.Credentials(oauthToken: nil, user: "octocat"))
    }

    @Test func toleratesMissingUser() {
        let creds = CopilotAuth.parseHosts(Data(#"{"github.com":{"oauth_token":"gho_X"}}"#.utf8))
        #expect(creds?.oauthToken == "gho_X")
        #expect(creds?.user == nil)
    }

    @Test func garbageIsNil() {
        #expect(CopilotAuth.parseApps(Data("not json".utf8)) == nil)
        #expect(CopilotAuth.parseApps(Data("[1,2]".utf8)) == nil)
        #expect(CopilotAuth.parseApps(Data("{}".utf8)) == nil)
        #expect(CopilotAuth.parseApps(Data(#"{"gitlab.com":{"oauth_token":"x"}}"#.utf8)) == nil)
        // github.com entry that is not an object is skipped, not crashed on.
        #expect(CopilotAuth.parseApps(Data(#"{"github.com:Iv1.x":42}"#.utf8)) == nil)
    }
}

// MARK: - Precedence

@Suite("CopilotPrecedence")
struct CopilotPrecedenceTests {
    @Test func appsWinsOverLegacyHosts() async throws {
        try await withCopilotRoot { root in
            try write(appsJSON, to: root, file: "apps.json")
            try write(hostsJSON, to: root, file: "hosts.json")
            let creds = CopilotAuth.load(root: root)
            #expect(creds?.oauthToken == "gho_FAKEFAKEFAKE")
            #expect(creds?.user == "octocat")
        }
    }

    @Test func fallsBackToHostsWhenAppsAbsent() async throws {
        try await withCopilotRoot { root in
            try write(hostsJSON, to: root, file: "hosts.json")
            #expect(CopilotAuth.load(root: root)?.oauthToken == "ghu_LEGACYFAKE")
        }
    }

    @Test func fallsBackToHostsWhenAppsHasNoUsableToken() async throws {
        try await withCopilotRoot { root in
            try write(#"{"github.com:Iv1.x":{"user":"octocat","oauth_token":""}}"#, to: root, file: "apps.json")
            try write(hostsJSON, to: root, file: "hosts.json")
            #expect(CopilotAuth.load(root: root)?.oauthToken == "ghu_LEGACYFAKE")
        }
    }

    @Test func fallsBackToHostsWhenAppsIsGarbage() async throws {
        try await withCopilotRoot { root in
            try write("not json at all", to: root, file: "apps.json")
            try write(hostsJSON, to: root, file: "hosts.json")
            #expect(CopilotAuth.load(root: root)?.oauthToken == "ghu_LEGACYFAKE")
        }
    }

    @Test func nilWhenNeitherFileYieldsToken() async throws {
        try await withCopilotRoot { root in
            try write(#"{"github.com":{"user":"octocat","oauth_token":""}}"#, to: root, file: "hosts.json")
            #expect(CopilotAuth.load(root: root) == nil)
        }
    }
}

// MARK: - Probe matrix

@Suite("CopilotProbe")
struct CopilotProbeTests {
    @Test func notConnectedWithoutRootDirectory() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-copilot-missing-\(UUID().uuidString)", isDirectory: true)
        let provider = CopilotProvider(root: missing)
        let connection = await provider.probeConnection()
        #expect(connection == .notConnected(hint: provider.descriptor.setupHint))
    }

    @Test func notConnectedWithEmptyDirectory() async throws {
        try await withCopilotRoot { root in
            let provider = CopilotProvider(root: root)
            let connection = await provider.probeConnection()
            #expect(connection == .notConnected(hint: provider.descriptor.setupHint))
        }
    }

    @Test func notConnectedWithEmptyToken() async throws {
        try await withCopilotRoot { root in
            try write(#"{"github.com:Iv1.x":{"user":"octocat","oauth_token":""}}"#, to: root, file: "apps.json")
            let provider = CopilotProvider(root: root)
            let connection = await provider.probeConnection()
            #expect(connection == .notConnected(hint: provider.descriptor.setupHint))
        }
    }

    @Test func availableWithAppsToken() async throws {
        try await withCopilotRoot { root in
            try write(appsJSON, to: root, file: "apps.json")
            #expect(await CopilotProvider(root: root).probeConnection() == .available)
        }
    }

    @Test func availableWithLegacyHostsTokenOnly() async throws {
        try await withCopilotRoot { root in
            try write(hostsJSON, to: root, file: "hosts.json")
            #expect(await CopilotProvider(root: root).probeConnection() == .available)
        }
    }

    @Test func fetchWithoutCredentialsThrowsNotLoggedIn() async throws {
        try await withCopilotRoot { root in
            let provider = CopilotProvider(root: root)
            await #expect(throws: ProviderFetchError.notLoggedIn(hint: provider.descriptor.setupHint)) {
                _ = try await provider.fetch()
            }
        }
    }
}

// MARK: - Request shape

@Suite("CopilotRequest")
struct CopilotRequestTests {
    @Test func usageEndpointAndExactHeaders() {
        #expect(CopilotAPI.usageURL.absoluteString == "https://api.github.com/copilot_internal/user")
        let headers = CopilotAPI.headers(token: "gho_FAKE")
        #expect(headers["Authorization"] == "token gho_FAKE") // "token", not "Bearer"
        #expect(headers["Accept"] == "application/json")
        #expect(headers["Editor-Version"] == "vscode/1.96.2")
        #expect(headers["Editor-Plugin-Version"] == "copilot-chat/0.26.7")
        #expect(headers["User-Agent"] == "GitHubCopilotChat/0.26.7")
        #expect(headers["X-Github-Api-Version"] == "2025-04-01")
        #expect(headers.count == 6)
    }
}

// MARK: - Response decoding

@Suite("CopilotDecoding")
struct CopilotDecodingTests {
    @Test func decodesLimitedAndUnlimitedSnapshots() {
        let json = #"""
        {"access_type_sku":"copilot_pro","copilot_plan":"individual",
         "quota_reset_date":"2026-07-01","assigned_date":"2025-01-15T10:24:36+01:00",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"overage_count":0,"overage_permitted":false,
             "percent_remaining":79.0,"quota_id":"premium_interactions","quota_remaining":237.0,
             "remaining":237.0,"unlimited":false},
           "chat":{"entitlement":0,"overage_count":0,"overage_permitted":false,
             "percent_remaining":100.0,"quota_id":"chat","remaining":0,"unlimited":true},
           "completions":{"unlimited":true}}}
        """#
        let response = CopilotAPI.parseUsage(Data(json.utf8))
        #expect(response.copilotPlan == "individual")
        #expect(response.quotaResetDate == "2026-07-01")
        #expect(response.premiumInteractions == CopilotAPI.QuotaSnapshot(
            unlimited: false, entitlement: 300, remaining: 237,
            percentRemaining: 79, overagePermitted: false
        ))
        #expect(response.chat?.unlimited == true)
        #expect(response.completions == CopilotAPI.QuotaSnapshot(unlimited: true))
    }

    @Test func toleratesIntDoubleAndStringNumbers() {
        let json = #"""
        {"quota_snapshots":{"premium_interactions":
          {"entitlement":300,"remaining":64.5,"percent_remaining":"21.5"}}}
        """#
        let premium = CopilotAPI.parseUsage(Data(json.utf8)).premiumInteractions
        #expect(premium?.entitlement == 300)
        #expect(premium?.remaining == 64.5)
        #expect(premium?.percentRemaining == 21.5)
    }

    @Test func everyFieldIsOptional() {
        let response = CopilotAPI.parseUsage(Data("{}".utf8))
        #expect(response == CopilotAPI.UsageResponse())

        let partial = CopilotAPI.parseUsage(Data(#"{"copilot_plan":"free","quota_snapshots":{}}"#.utf8))
        #expect(partial.copilotPlan == "free")
        #expect(partial.premiumInteractions == nil)
        #expect(partial.chat == nil)
    }

    @Test func garbageYieldsEmptyResponseNotCrash() {
        #expect(CopilotAPI.parseUsage(Data("nope".utf8)) == CopilotAPI.UsageResponse())
        #expect(CopilotAPI.parseUsage(Data("[1]".utf8)) == CopilotAPI.UsageResponse())
        // Snapshot that is not an object is dropped; booleans are not numbers.
        let odd = CopilotAPI.parseUsage(Data(#"""
        {"copilot_plan":"","quota_snapshots":{"premium_interactions":7,
         "chat":{"entitlement":true,"remaining":"abc"}}}
        """#.utf8))
        #expect(odd.copilotPlan == nil) // empty string treated as absent
        #expect(odd.premiumInteractions == nil)
        #expect(odd.chat == CopilotAPI.QuotaSnapshot())
    }
}

// MARK: - Utilization math

@Suite("CopilotMath")
struct CopilotMathTests {
    @Test func utilizationIsHundredMinusPercentRemaining() {
        let snapshot = CopilotAPI.QuotaSnapshot(entitlement: 300, remaining: 237, percentRemaining: 79)
        #expect(CopilotAPI.utilization(of: snapshot) == 21)
    }

    @Test func clampsOverAndUnderQuotaPercents() {
        // Negative percent_remaining (over quota with overage) clamps to 100.
        #expect(CopilotAPI.utilization(of: .init(percentRemaining: -15)) == 100)
        // percent_remaining above 100 clamps to 0 used.
        #expect(CopilotAPI.utilization(of: .init(percentRemaining: 120)) == 0)
        #expect(CopilotAPI.utilization(of: .init(percentRemaining: 0)) == 100)
        #expect(CopilotAPI.utilization(of: .init(percentRemaining: 100)) == 0)
    }

    @Test func fallsBackToEntitlementMathWhenPercentMissing() {
        let snapshot = CopilotAPI.QuotaSnapshot(entitlement: 300, remaining: 75)
        #expect(CopilotAPI.utilization(of: snapshot) == 75)
        // Fallback also clamps: negative remaining means over quota.
        #expect(CopilotAPI.utilization(of: .init(entitlement: 500, remaining: -75)) == 100)
        #expect(CopilotAPI.utilization(of: .init(entitlement: 500, remaining: 600)) == 0)
    }

    @Test func underdeterminedSnapshotsYieldNil() {
        #expect(CopilotAPI.utilization(of: .init()) == nil)
        #expect(CopilotAPI.utilization(of: .init(entitlement: 300)) == nil)
        #expect(CopilotAPI.utilization(of: .init(remaining: 30)) == nil)
        // Zero entitlement cannot produce a meaningful percentage.
        #expect(CopilotAPI.utilization(of: .init(entitlement: 0, remaining: 0)) == nil)
        // Unlimited quotas carry no gauge signal even with counts present.
        #expect(CopilotAPI.utilization(of: .init(unlimited: true, entitlement: 300, remaining: 0)) == nil)
    }

    @Test func detailUsesWholeNumbers() {
        #expect(CopilotAPI.detail(for: .init(entitlement: 300, remaining: 237)) == "63 of 300 requests")
        #expect(CopilotAPI.detail(for: .init(entitlement: 300, remaining: 235.5)) == "65 of 300 requests")
        #expect(CopilotAPI.detail(for: .init(entitlement: 50, remaining: 0)) == "50 of 50 requests")
        #expect(CopilotAPI.detail(for: .init(entitlement: 300)) == nil)
        #expect(CopilotAPI.detail(for: .init(remaining: 10)) == nil)
    }
}

// MARK: - Reset date

@Suite("CopilotResetDate")
struct CopilotResetDateTests {
    private func calendar(_ timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        return calendar
    }

    @Test func parsesAsStartOfLocalDayNotUTC() {
        // Midnight New York (EDT, UTC−4) is 04:00Z — proving the plain
        // yyyy-MM-dd is anchored to the LOCAL calendar day.
        let newYork = CopilotAPI.parseResetDate("2026-07-01", calendar: calendar("America/New_York"))
        #expect(newYork == Date(timeIntervalSince1970: 1_782_878_400)) // 2026-07-01T04:00:00Z

        let utc = CopilotAPI.parseResetDate("2026-07-01", calendar: calendar("UTC"))
        #expect(utc == Date(timeIntervalSince1970: 1_782_864_000)) // 2026-07-01T00:00:00Z

        let tokyo = CopilotAPI.parseResetDate("2026-07-01", calendar: calendar("Asia/Tokyo"))
        #expect(tokyo == Date(timeIntervalSince1970: 1_782_831_600)) // 2026-06-30T15:00:00Z
    }

    @Test func defaultCalendarRoundTripsToStartOfDay() throws {
        let calendar = Calendar.current
        let date = try #require(CopilotAPI.parseResetDate("2026-07-01", calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 1)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(date == calendar.startOfDay(for: date))
    }

    @Test func rejectsNonDateStrings() {
        for bad in ["", "2026-7", "07/01/2026", "2026-13-01", "2026-12-32", "26-07-01",
                    "yesterday", "2026-07-01T00:00:00Z", "2026-07", "abcd-ef-gh"] {
            #expect(CopilotAPI.parseResetDate(bad, calendar: calendar("UTC")) == nil, "\(bad)")
        }
    }
}

// MARK: - Plan label

@Suite("CopilotPlanLabel")
struct CopilotPlanLabelTests {
    @Test func capitalizesRawPlanWithoutInventingNames() {
        #expect(CopilotAPI.planLabel("individual") == "Individual")
        #expect(CopilotAPI.planLabel("business") == "Business")
        #expect(CopilotAPI.planLabel("enterprise") == "Enterprise")
        #expect(CopilotAPI.planLabel("free") == "Free")
        #expect(CopilotAPI.planLabel("individual_pro") == "Individual Pro")
        #expect(CopilotAPI.planLabel("unknown") == "Unknown")
    }

    @Test func blankPlansAreNil() {
        #expect(CopilotAPI.planLabel(nil) == nil)
        #expect(CopilotAPI.planLabel("") == nil)
        #expect(CopilotAPI.planLabel("   ") == nil)
    }
}

// MARK: - Account label

@Suite("CopilotAccountLabel")
struct CopilotAccountLabelTests {
    @Test func masksLoginToTwoCharsAndEllipsis() {
        #expect(CopilotAuth.maskedUser("octocat") == "oc…")
        #expect(CopilotAuth.maskedUser("ab") == "ab…")
        #expect(CopilotAuth.maskedUser("a") == "a…")
        #expect(CopilotAuth.maskedUser("  octocat  ") == "oc…")
        #expect(CopilotAuth.maskedUser("") == nil)
        #expect(CopilotAuth.maskedUser("   ") == nil)
    }
}

// MARK: - Snapshot assembly

@Suite("CopilotSnapshot")
struct CopilotSnapshotTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func assemblesLimitedPremiumSnapshot() {
        let response = CopilotAPI.parseUsage(Data(#"""
        {"copilot_plan":"individual","quota_reset_date":"2026-07-01",
         "quota_snapshots":{
           "premium_interactions":{"unlimited":false,"entitlement":300,"remaining":237,
             "percent_remaining":79.0,"overage_permitted":false},
           "chat":{"unlimited":true},
           "completions":{"unlimited":true}}}
        """#.utf8))
        let snapshot = CopilotProvider.makeSnapshot(
            response: response,
            credentials: CopilotAuth.Credentials(oauthToken: "gho_FAKE", user: "octocat"),
            calendar: utcCalendar
        )

        #expect(snapshot.providerID == .copilot)
        #expect(snapshot.plan == "Individual")
        #expect(snapshot.accountLabel == "oc…")
        #expect(snapshot.primary?.id == "premium")
        #expect(snapshot.primary?.title == "Premium Requests")
        #expect(snapshot.primary?.systemImage == "calendar")
        #expect(snapshot.primary?.utilization == 21)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_782_864_000))
        #expect(snapshot.primary?.windowDuration == nil)
        #expect(snapshot.primary?.detail == "63 of 300 requests")
        // Unlimited chat/completions carry no gauge signal.
        #expect(snapshot.extraWindows.isEmpty)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.statusNotes.isEmpty)
        // Copilot exposes no token/cost ledger.
        #expect(snapshot.tokens == nil)
        #expect(snapshot.dailyUsage.isEmpty)
    }

    @Test func unlimitedPremiumBecomesStatusNote() {
        let response = CopilotAPI.parseUsage(Data(#"""
        {"copilot_plan":"business","quota_reset_date":"2026-07-01",
         "quota_snapshots":{
           "premium_interactions":{"unlimited":true,"entitlement":0,"remaining":0,"percent_remaining":100},
           "chat":{"unlimited":false,"entitlement":100,"remaining":25,"percent_remaining":25},
           "completions":{"unlimited":false,"entitlement":2000,"remaining":1000}}}
        """#.utf8))
        let snapshot = CopilotProvider.makeSnapshot(
            response: response,
            credentials: CopilotAuth.Credentials(oauthToken: "gho_FAKE", user: "hubber"),
            calendar: utcCalendar
        )

        #expect(snapshot.primary == nil)
        #expect(snapshot.statusNotes == ["Premium requests: unlimited"])
        #expect(snapshot.plan == "Business")
        #expect(snapshot.extraWindows.count == 2)
        #expect(snapshot.extraWindows[0].id == "chat")
        #expect(snapshot.extraWindows[0].title == "Chat")
        #expect(snapshot.extraWindows[0].systemImage == "sparkles")
        #expect(snapshot.extraWindows[0].utilization == 75)
        #expect(snapshot.extraWindows[0].resetsAt == Date(timeIntervalSince1970: 1_782_864_000))
        // Completions percent missing → fallback math (2000−1000)/2000.
        #expect(snapshot.extraWindows[1].id == "completions")
        #expect(snapshot.extraWindows[1].title == "Completions")
        #expect(snapshot.extraWindows[1].utilization == 50)
        #expect(snapshot.extraWindows[1].detail == "1000 of 2000 requests")
    }

    @Test func absentPremiumGetsAppropriateNote() {
        let response = CopilotAPI.parseUsage(Data(#"{"copilot_plan":"free","quota_snapshots":{}}"#.utf8))
        let snapshot = CopilotProvider.makeSnapshot(
            response: response,
            credentials: CopilotAuth.Credentials(oauthToken: "gho_FAKE", user: nil)
        )
        #expect(snapshot.primary == nil)
        #expect(snapshot.statusNotes == ["No premium request quota reported"])
        #expect(snapshot.plan == "Free")
        #expect(snapshot.accountLabel == nil)
    }

    @Test func underdeterminedPremiumGetsNoteInsteadOfFakeGauge() {
        // Business token-based billing placeholder: entitlement 0, remaining 0,
        // percent 100 — would render a misleading "0% used" gauge.
        let response = CopilotAPI.parseUsage(Data(#"""
        {"copilot_plan":"business",
         "quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}
        """#.utf8))
        let snapshot = CopilotProvider.makeSnapshot(
            response: response,
            credentials: CopilotAuth.Credentials(oauthToken: "gho_FAKE", user: "hubber")
        )
        #expect(snapshot.primary == nil)
        #expect(snapshot.statusNotes == ["No premium request quota reported"])
    }

    @Test func missingResetDateLeavesWindowOpenEnded() {
        let response = CopilotAPI.parseUsage(Data(#"""
        {"copilot_plan":"individual",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":150,"percent_remaining":50}}}
        """#.utf8))
        let snapshot = CopilotProvider.makeSnapshot(
            response: response,
            credentials: CopilotAuth.Credentials(oauthToken: "gho_FAKE", user: "octocat")
        )
        #expect(snapshot.primary?.utilization == 50)
        #expect(snapshot.primary?.resetsAt == nil)
    }

    @Test func tokenExpiredHintMatchesSpec() {
        #expect(CopilotProvider.tokenExpiredHint
            == "GitHub token expired — sign in to Copilot again in your editor.")
    }
}

// MARK: - Descriptor

@Suite("CopilotDescriptor")
struct CopilotDescriptorTests {
    @Test func descriptorAndTabOrder() {
        let provider = CopilotProvider()
        #expect(provider.id == .copilot)
        #expect(provider.descriptor.name == "Copilot")
        #expect(provider.descriptor.shortCode == "COP")
        #expect(provider.descriptor.appBundleID == nil)
        #expect(provider.descriptor.webURL.absoluteString == "https://github.com/settings/copilot")
        #expect(provider.descriptor.setupHint == "Sign in to GitHub Copilot in your editor to start tracking.")
        // Canonical order: Claude / Codex / Cursor / Copilot / Gemini.
        #expect(ProviderID.allCases == [.claude, .codex, .cursor, .copilot, .gemini])
    }
}
