import Foundation
import Testing
@testable import Pulse

// MARK: - Test helpers

/// Stub transport that always answers with one canned response.
private struct GeminiStubTransport: GeminiTransport {
    var status: Int = 200
    var body: Data = Data()

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        (status, body)
    }
}

/// Stub transport that routes by URL substring and fails any unrouted call —
/// so a test also proves which endpoints were NOT hit.
private struct GeminiRoutingTransport: GeminiTransport {
    var routes: [String: (status: Int, body: Data)]

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let url = request.url?.absoluteString ?? ""
        guard let match = routes.first(where: { url.contains($0.key) })?.value else {
            throw ProviderFetchError.network(description: "unrouted request in test")
        }
        return match
    }
}

/// Counts calls to prove in-memory caching (no second refresh round-trip).
private actor GeminiCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct GeminiCountingTransport: GeminiTransport {
    let counter: GeminiCallCounter
    var status: Int = 200
    var body: Data = Data()

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        await counter.increment()
        return (status, body)
    }
}

/// Runs `body` against a throwaway ~/.gemini-style root in the temp dir.
private func withGeminiRoot(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pulse-gemini-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func write(_ json: String, to root: URL, file: String) throws {
    try Data(json.utf8).write(to: root.appendingPathComponent(file))
}

/// Unsigned base64url JWT with the given payload claims (signature is junk —
/// the JWT helper only reads the payload segment).
private func fakeIDToken(_ claims: [String: String]) throws -> String {
    func segment(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return try "\(segment(["alg": "none"])).\(segment(claims)).sig"
}

/// Far-future expiry (epoch ms) so stored creds count as fresh in tests.
private let farFutureExpiryMS: Double = 4_102_444_800_000 // 2100-01-01T00:00:00Z

// MARK: - Credentials

@Suite("GeminiCredentials")
struct GeminiCredentialsTests {
    @Test func decodesOAuthCredsFile() {
        let json = """
        {"access_token":"at-1","refresh_token":"rt-1","scope":"openid email",
         "token_type":"Bearer","id_token":"x.y.z","expiry_date":1781055688000}
        """
        let creds = GeminiAuth.parseCredentials(Data(json.utf8))
        #expect(creds?.accessToken == "at-1")
        #expect(creds?.refreshToken == "rt-1")
        #expect(creds?.idToken == "x.y.z")
        // expiry_date is epoch MILLISECONDS.
        #expect(creds?.expiry == Date(timeIntervalSince1970: 1_781_055_688))
    }

    @Test func toleratesMissingFieldsAndStringExpiry() {
        let creds = GeminiAuth.parseCredentials(Data(#"{"refresh_token":"rt"}"#.utf8))
        #expect(creds?.refreshToken == "rt")
        #expect(creds?.accessToken == nil)
        #expect(creds?.expiry == nil)

        let stringExpiry = GeminiAuth.parseCredentials(Data(#"{"expiry_date":"2000000000000"}"#.utf8))
        #expect(stringExpiry?.expiry == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func garbageIsNil() {
        #expect(GeminiAuth.parseCredentials(Data("not json".utf8)) == nil)
        #expect(GeminiAuth.parseCredentials(Data("[1,2]".utf8)) == nil)
    }

    @Test func freshnessUsesMillisecondsWithSixtySecondLeeway() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        var creds = GeminiAuth.Credentials(
            accessToken: "at", refreshToken: "rt",
            expiryDateMS: 2_000_000_000_000, idToken: nil
        )
        // Stale once expiry − 60 s ≤ now.
        #expect(creds.isFresh(now: expiry.addingTimeInterval(-61)))
        #expect(!creds.isFresh(now: expiry.addingTimeInterval(-60)))
        #expect(!creds.isFresh(now: expiry.addingTimeInterval(-30)))
        #expect(!creds.isFresh(now: expiry.addingTimeInterval(10)))

        creds.accessToken = ""
        #expect(!creds.isFresh(now: expiry.addingTimeInterval(-3600)))
        creds.accessToken = "at"
        creds.expiryDateMS = nil
        #expect(!creds.isFresh(now: expiry.addingTimeInterval(-3600)))
    }
}

// MARK: - settings.json

@Suite("GeminiSettings")
struct GeminiSettingsTests {
    @Test func extractsNestedSelectedType() {
        let json = #"{"theme":"dark","security":{"auth":{"selectedType":"gemini-api-key","useExternal":false}}}"#
        #expect(GeminiAuth.selectedAuthType(fromSettingsData: Data(json.utf8)) == "gemini-api-key")
    }

    @Test func absentOrMalformedKeyIsNil() {
        for json in [
            "{}",
            #"{"security":{}}"#,
            #"{"security":{"auth":{}}}"#,
            #"{"security":{"auth":{"selectedType":42}}}"#,
            #"{"security":{"auth":{"selectedType":"   "}}}"#,
            #"{"selectedAuthType":"oauth-personal"}"#, // top-level key is NOT the CLI's location
            "not json",
        ] {
            #expect(GeminiAuth.selectedAuthType(fromSettingsData: Data(json.utf8)) == nil, "\(json)")
        }
    }
}

// MARK: - Probe matrix

@Suite("GeminiProbe")
struct GeminiProbeTests {
    private let oauthHint = "Gemini quota tracking needs Google sign-in (oauth-personal)"

    @Test func notConnectedWithoutCredsFile() async throws {
        try await withGeminiRoot { root in
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            let connection = await provider.probeConnection()
            #expect(connection == .notConnected(hint: provider.descriptor.setupHint))
        }
    }

    @Test func notConnectedWithoutRefreshToken() async throws {
        try await withGeminiRoot { root in
            try write(#"{"access_token":"at","refresh_token":""}"#, to: root, file: "oauth_creds.json")
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            let connection = await provider.probeConnection()
            #expect(connection == .notConnected(hint: provider.descriptor.setupHint))
        }
    }

    @Test func apiKeyModeGetsOAuthHint() async throws {
        try await withGeminiRoot { root in
            try write(#"{"access_token":"at","refresh_token":"rt"}"#, to: root, file: "oauth_creds.json")
            try write(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#, to: root, file: "settings.json")
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            #expect(await provider.probeConnection() == .notConnected(hint: oauthHint))
        }
    }

    @Test func vertexModeGetsOAuthHint() async throws {
        try await withGeminiRoot { root in
            try write(#"{"refresh_token":"rt"}"#, to: root, file: "oauth_creds.json")
            try write(#"{"security":{"auth":{"selectedType":"vertex-ai"}}}"#, to: root, file: "settings.json")
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            #expect(await provider.probeConnection() == .notConnected(hint: oauthHint))
        }
    }

    @Test func availableWithOAuthPersonal() async throws {
        try await withGeminiRoot { root in
            try write(#"{"refresh_token":"rt"}"#, to: root, file: "oauth_creds.json")
            try write(#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#, to: root, file: "settings.json")
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            #expect(await provider.probeConnection() == .available)
        }
    }

    @Test func availableWhenAuthTypeUnset() async throws {
        try await withGeminiRoot { root in
            try write(#"{"refresh_token":"rt"}"#, to: root, file: "oauth_creds.json")
            let provider = GeminiProvider(root: root, transport: GeminiStubTransport())
            #expect(await provider.probeConnection() == .available)

            // Settings file without the nested key behaves like no selection.
            try write(#"{"security":{}}"#, to: root, file: "settings.json")
            #expect(await provider.probeConnection() == .available)
        }
    }
}

// MARK: - Bucket math

@Suite("GeminiQuotaMath")
struct GeminiQuotaMathTests {
    @Test func keepsLowestFractionPerModelAndSortsWorstFirst() {
        let buckets = [
            GeminiQuotaAPI.QuotaBucket(remainingFraction: 0.8, resetTime: "2026-01-01T00:00:00Z", tokenType: "output", modelId: "gemini-2.5-pro"),
            GeminiQuotaAPI.QuotaBucket(remainingFraction: 0.4, resetTime: "2026-01-01T00:00:00Z", tokenType: "input", modelId: "gemini-2.5-pro"),
            GeminiQuotaAPI.QuotaBucket(remainingAmount: "900", remainingFraction: 0.9, resetTime: "2026-01-01T01:00:00Z", modelId: "gemini-2.5-flash"),
        ]
        let windows = GeminiQuotaAPI.quotaWindows(from: buckets)
        #expect(windows.count == 2)
        // Pro's worst lane is 0.4 remaining → 60% used → headline.
        #expect(windows[0].id == "quota.gemini-2.5-pro")
        #expect(abs(windows[0].utilization - 60) < 0.0001)
        #expect(windows[0].title == "gemini-2.5-pro")
        #expect(windows[0].systemImage == "sparkle")
        #expect(windows[0].windowDuration == TimeInterval(24 * 3600))
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_767_225_600)) // 2026-01-01T00:00:00Z
        // Flash: 0.9 remaining → 10% used.
        #expect(windows[1].id == "quota.gemini-2.5-flash")
        #expect(abs(windows[1].utilization - 10) < 0.0001)
    }

    @Test func skipsBucketsWithoutModelOrFraction() {
        let buckets = [
            GeminiQuotaAPI.QuotaBucket(remainingFraction: 0.5),                      // no model
            GeminiQuotaAPI.QuotaBucket(resetTime: "2026-01-01T00:00:00Z", modelId: "gemini-2.5-pro"), // no fraction
        ]
        #expect(GeminiQuotaAPI.quotaWindows(from: buckets).isEmpty)
    }

    @Test func clampsOutOfRangeFractions() {
        let windows = GeminiQuotaAPI.quotaWindows(from: [
            GeminiQuotaAPI.QuotaBucket(remainingFraction: 1.2, modelId: "a"),
            GeminiQuotaAPI.QuotaBucket(remainingFraction: -0.2, modelId: "b"),
        ])
        #expect(windows.count == 2)
        #expect(windows[0].id == "quota.b")
        #expect(windows[0].utilization == 100)
        #expect(windows[1].id == "quota.a")
        #expect(windows[1].utilization == 0)
    }

    @Test func parsesISOResetTimes() {
        #expect(GeminiQuotaAPI.parseISO("2026-01-01T00:00:00Z") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(GeminiQuotaAPI.parseISO("2026-01-01T00:00:00.500Z") == Date(timeIntervalSince1970: 1_767_225_600.5))
        #expect(GeminiQuotaAPI.parseISO("2026-01-01T01:00:00+00:00") == Date(timeIntervalSince1970: 1_767_225_600 + 3600))
        #expect(GeminiQuotaAPI.parseISO("yesterday") == nil)
    }
}

// MARK: - Tier label

@Suite("GeminiTierLabel")
struct GeminiTierLabelTests {
    @Test func mapsKnownTiers() {
        #expect(GeminiQuotaAPI.tierLabel(id: "free-tier", isWorkspace: false) == "Free")
        #expect(GeminiQuotaAPI.tierLabel(id: "standard-tier", isWorkspace: false) == "Paid")
        #expect(GeminiQuotaAPI.tierLabel(id: "legacy-tier", isWorkspace: false) == "Legacy")
        #expect(GeminiQuotaAPI.tierLabel(id: nil, isWorkspace: false) == nil)
        #expect(GeminiQuotaAPI.tierLabel(id: "enterprise-tier", isWorkspace: false) == "Enterprise Tier")
    }

    @Test func appendsWorkspaceForHostedDomain() {
        #expect(GeminiQuotaAPI.tierLabel(id: "free-tier", isWorkspace: true) == "Free (Workspace)")
        #expect(GeminiQuotaAPI.tierLabel(id: "standard-tier", isWorkspace: true) == "Paid (Workspace)")
    }

    @Test func workspaceComesFromIDTokenHDClaim() async throws {
        try await withGeminiRoot { root in
            let token = try fakeIDToken(["email": "dev@corp.example", "hd": "corp.example"])
            try write(
                #"{"access_token":"at","refresh_token":"rt","expiry_date":\#(Int(farFutureExpiryMS)),"id_token":"\#(token)"}"#,
                to: root, file: "oauth_creds.json"
            )
            let auth = GeminiAuth(root: root, transport: GeminiStubTransport(), setupHint: "setup")
            let claims = await auth.idTokenClaims()
            #expect(claims.email == "dev@corp.example")
            #expect(claims.isWorkspace)

            // Personal account: no hd claim.
            let personal = try fakeIDToken(["email": "someone@gmail.com"])
            try write(
                #"{"refresh_token":"rt","id_token":"\#(personal)"}"#,
                to: root, file: "oauth_creds.json"
            )
            let personalAuth = GeminiAuth(root: root, transport: GeminiStubTransport(), setupHint: "setup")
            let personalClaims = await personalAuth.idTokenClaims()
            #expect(personalClaims.email == "someone@gmail.com")
            #expect(!personalClaims.isWorkspace)
        }
    }
}

// MARK: - Account label

@Suite("GeminiAccountLabel")
struct GeminiAccountLabelTests {
    @Test func masksEmails() {
        #expect(GeminiAuth.maskedEmail("christian@example.com") == "ch…@example.com")
        #expect(GeminiAuth.maskedEmail("ab@x.de") == "ab…@x.de")
        #expect(GeminiAuth.maskedEmail("a@x.de") == "a…@x.de")
        #expect(GeminiAuth.maskedEmail("@x.de") == nil)
        #expect(GeminiAuth.maskedEmail("no-at-sign") == nil)
        #expect(GeminiAuth.maskedEmail("dangling@") == nil)
    }

    @Test func prefersGoogleAccountsThenIDToken() async throws {
        try await withGeminiRoot { root in
            let token = try fakeIDToken(["email": "fallback@example.com"])
            try write(#"{"refresh_token":"rt","id_token":"\#(token)"}"#, to: root, file: "oauth_creds.json")

            // No google_accounts.json → id_token email claim.
            let auth = GeminiAuth(root: root, transport: GeminiStubTransport(), setupHint: "setup")
            #expect(await auth.accountLabel() == "fa…@example.com")

            // google_accounts.json active wins.
            try write(#"{"active":"developer@example.com","old":["fallback@example.com"]}"#, to: root, file: "google_accounts.json")
            #expect(await auth.accountLabel() == "de…@example.com")
        }
    }
}

// MARK: - Token refresh

/// Fixture OAuth client. Built by concatenation so no literal in this file
/// resembles a real Google credential (GitHub push protection scans tests too).
let fakeOAuthClient = GeminiOAuthClient(
    clientID: "123456789012-" + String(repeating: "a", count: 24) + ".apps." + "googleusercontent.com",
    clientSecret: "GOCSPX" + "-" + "UNITTESTFAKEVALUE"
)

@Suite("GeminiRefresh")
struct GeminiRefreshTests {
    @Test func refreshBodyIsExactFormEncoding() {
        let body = GeminiAuth.refreshRequestBody(refreshToken: "1//0abc+def/ghi", client: fakeOAuthClient)
        // Client id/secret consist of unreserved characters → encode to themselves.
        #expect(body == "grant_type=refresh_token"
            + "&refresh_token=1%2F%2F0abc%2Bdef%2Fghi"
            + "&client_id=\(fakeOAuthClient.clientID)"
            + "&client_secret=\(fakeOAuthClient.clientSecret)")
    }

    @Test func refreshRequestShape() {
        let request = GeminiAuth.refreshRequest(refreshToken: "rt", client: fakeOAuthClient)
        #expect(request.url == GeminiAuth.tokenEndpoint)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == GeminiAuth.refreshRequestBody(refreshToken: "rt", client: fakeOAuthClient))
    }

    @Test func locatorExtractsClientFromBundledSource() {
        let source = "var x={OAUTH_CLIENT_ID:\"\(fakeOAuthClient.clientID)\","
            + "OAUTH_CLIENT_SECRET:\"\(fakeOAuthClient.clientSecret)\"};"
        let client = GeminiOAuthClientLocator.extract(fromSource: source)
        #expect(client == fakeOAuthClient)
        #expect(GeminiOAuthClientLocator.extract(fromSource: "no credentials here") == nil)
        // Both constants must come from the same source.
        #expect(GeminiOAuthClientLocator.extract(
            fromSource: "id only: \(fakeOAuthClient.clientID)"
        ) == nil)
    }

    @Test func usesStoredTokenWhileFresh() async throws {
        try await withGeminiRoot { root in
            try write(
                #"{"access_token":"at-live","refresh_token":"rt","expiry_date":\#(Int(farFutureExpiryMS))}"#,
                to: root, file: "oauth_creds.json"
            )
            // Any network call would fail the test (unrouted).
            let auth = GeminiAuth(root: root, transport: GeminiRoutingTransport(routes: [:]), setupHint: "setup", oauthClient: fakeOAuthClient)
            #expect(try await auth.accessToken() == "at-live")
        }
    }

    @Test func invalidGrantMapsToNotLoggedIn() async throws {
        try await withGeminiRoot { root in
            try write(#"{"access_token":"stale","refresh_token":"rt","expiry_date":1000}"#, to: root, file: "oauth_creds.json")
            let transport = GeminiStubTransport(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"Token has been revoked."}"#.utf8))
            let auth = GeminiAuth(root: root, transport: transport, setupHint: "setup", oauthClient: fakeOAuthClient)
            await #expect(throws: ProviderFetchError.notLoggedIn(hint: "Sign in again with `gemini`")) {
                _ = try await auth.accessToken()
            }
        }
    }

    @Test func otherRefreshFailuresMapToHTTP() async throws {
        try await withGeminiRoot { root in
            try write(#"{"access_token":"stale","refresh_token":"rt","expiry_date":1000}"#, to: root, file: "oauth_creds.json")
            let transport = GeminiStubTransport(status: 500, body: Data())
            let auth = GeminiAuth(root: root, transport: transport, setupHint: "setup", oauthClient: fakeOAuthClient)
            await #expect(throws: ProviderFetchError.http(status: 500)) {
                _ = try await auth.accessToken()
            }
        }
    }

    @Test func successfulRefreshIsCachedInMemoryAndNeverWritesCreds() async throws {
        try await withGeminiRoot { root in
            let credsJSON = #"{"access_token":"stale","refresh_token":"rt","expiry_date":1000}"#
            try write(credsJSON, to: root, file: "oauth_creds.json")
            let counter = GeminiCallCounter()
            let transport = GeminiCountingTransport(
                counter: counter,
                body: Data(#"{"access_token":"fresh-token","expires_in":3600,"token_type":"Bearer"}"#.utf8)
            )
            let auth = GeminiAuth(root: root, transport: transport, setupHint: "setup", oauthClient: fakeOAuthClient)

            #expect(try await auth.accessToken() == "fresh-token")
            #expect(try await auth.accessToken() == "fresh-token")
            // Second call served from the in-memory cache.
            #expect(await counter.count == 1)
            // The CLI owns oauth_creds.json — it must be byte-identical.
            let onDisk = try Data(contentsOf: root.appendingPathComponent("oauth_creds.json"))
            #expect(onDisk == Data(credsJSON.utf8))
        }
    }

    @Test func missingRefreshTokenWithStaleAccessTokenSignalsSignIn() async throws {
        try await withGeminiRoot { root in
            try write(#"{"access_token":"stale","expiry_date":1000}"#, to: root, file: "oauth_creds.json")
            let auth = GeminiAuth(root: root, transport: GeminiStubTransport(), setupHint: "setup")
            await #expect(throws: ProviderFetchError.notLoggedIn(hint: "Sign in again with `gemini`")) {
                _ = try await auth.accessToken()
            }
        }
    }
}

// MARK: - RPC response decoding

@Suite("GeminiAPIDecoding")
struct GeminiAPIDecodingTests {
    @Test func parsesLoadCodeAssistWithStringProject() {
        let json = """
        {"currentTier":{"id":"standard-tier","name":"Standard"},
         "paidTier":{"id":"standard-tier"},
         "allowedTiers":[{"id":"free-tier","isDefault":true}],
         "cloudaicompanionProject":"proj-1"}
        """
        let parsed = GeminiQuotaAPI.parseLoadCodeAssist(Data(json.utf8))
        #expect(parsed == GeminiQuotaAPI.LoadCodeAssist(tierID: "standard-tier", project: "proj-1"))
    }

    @Test func parsesLoadCodeAssistWithObjectProject() {
        let byID = GeminiQuotaAPI.parseLoadCodeAssist(Data(#"{"cloudaicompanionProject":{"id":"proj-2","name":"x"}}"#.utf8))
        #expect(byID.project == "proj-2")
        let byProjectId = GeminiQuotaAPI.parseLoadCodeAssist(Data(#"{"cloudaicompanionProject":{"projectId":"proj-3"}}"#.utf8))
        #expect(byProjectId.project == "proj-3")
    }

    @Test func loadCodeAssistToleratesGarbageAndEmptiness() {
        #expect(GeminiQuotaAPI.parseLoadCodeAssist(Data("[]".utf8)) == GeminiQuotaAPI.LoadCodeAssist(tierID: nil, project: nil))
        #expect(GeminiQuotaAPI.parseLoadCodeAssist(Data("{}".utf8)).project == nil)
        #expect(GeminiQuotaAPI.parseLoadCodeAssist(Data(#"{"cloudaicompanionProject":""}"#.utf8)).project == nil)
    }

    @Test func parsesQuotaBucketsLossily() {
        let json = """
        {"buckets":[
          {"remainingAmount":"950","remainingFraction":0.95,"resetTime":"2026-01-01T00:00:00Z","tokenType":"input","modelId":"gemini-2.5-pro"},
          {"remainingFraction":"0.5","modelId":"m2"},
          {"remainingFraction":{"bad":true},"modelId":"m3"},
          42
        ]}
        """
        let buckets = GeminiQuotaAPI.parseQuotaBuckets(Data(json.utf8))
        #expect(buckets.count == 3)
        #expect(buckets[0] == GeminiQuotaAPI.QuotaBucket(
            remainingAmount: "950", remainingFraction: 0.95,
            resetTime: "2026-01-01T00:00:00Z", tokenType: "input", modelId: "gemini-2.5-pro"
        ))
        #expect(buckets[1].remainingFraction == 0.5) // string fraction tolerated
        #expect(buckets[2].remainingFraction == nil) // bad fraction dropped, bucket kept
        #expect(buckets[2].modelId == "m3")
    }

    @Test func emptyOrMissingBucketsYieldEmptyArray() {
        #expect(GeminiQuotaAPI.parseQuotaBuckets(Data("{}".utf8)).isEmpty)
        #expect(GeminiQuotaAPI.parseQuotaBuckets(Data(#"{"buckets":[]}"#.utf8)).isEmpty)
        #expect(GeminiQuotaAPI.parseQuotaBuckets(Data("garbage".utf8)).isEmpty)
    }
}

// MARK: - Full fetch through the provider

@Suite("GeminiFetch")
struct GeminiFetchTests {
    private func writeFreshCreds(to root: URL) throws {
        try write(
            #"{"access_token":"at-live","refresh_token":"rt","expiry_date":\#(Int(farFutureExpiryMS))}"#,
            to: root, file: "oauth_creds.json"
        )
    }

    @Test func assemblesQuotaSnapshot() async throws {
        try await withGeminiRoot { root in
            try writeFreshCreds(to: root)
            try write(#"{"active":"developer@example.com","old":[]}"#, to: root, file: "google_accounts.json")
            let load = #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"proj-1"}"#
            let quota = """
            {"buckets":[
              {"remainingFraction":0.4,"resetTime":"2026-01-01T00:00:00Z","tokenType":"input","modelId":"gemini-2.5-pro"},
              {"remainingFraction":0.55,"tokenType":"output","modelId":"gemini-2.5-pro"},
              {"remainingAmount":"900","remainingFraction":0.9,"resetTime":"2026-01-01T01:00:00Z","modelId":"gemini-2.5-flash"}
            ]}
            """
            let provider = GeminiProvider(root: root, transport: GeminiRoutingTransport(routes: [
                ":loadCodeAssist": (200, Data(load.utf8)),
                ":retrieveUserQuota": (200, Data(quota.utf8)),
            ]))

            let snapshot = try await provider.fetch()
            #expect(snapshot.plan == "Paid")
            #expect(snapshot.accountLabel == "de…@example.com")
            #expect(snapshot.primary?.id == "quota")
            #expect(snapshot.primary?.title == "Daily Quota")
            #expect(snapshot.primary?.systemImage == "gauge")
            #expect(snapshot.primary?.detail == "gemini-2.5-pro")
            #expect(abs((snapshot.primary?.utilization ?? 0) - 60) < 0.0001)
            #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_767_225_600))
            #expect(snapshot.primary?.windowDuration == TimeInterval(24 * 3600))
            #expect(snapshot.extraWindows.count == 1)
            #expect(snapshot.extraWindows[0].id == "quota.gemini-2.5-flash")
            #expect(snapshot.extraWindows[0].title == "gemini-2.5-flash")
            #expect(snapshot.extraWindows[0].systemImage == "sparkle")
            #expect(abs(snapshot.extraWindows[0].utilization - 10) < 0.0001)
            // Gemini exposes no token/cost ledger.
            #expect(snapshot.tokens == nil)
            #expect(snapshot.dailyUsage.isEmpty)
            #expect(snapshot.statusNotes.isEmpty)
        }
    }

    @Test func missingProjectShortCircuitsWithStatusNote() async throws {
        try await withGeminiRoot { root in
            try writeFreshCreds(to: root)
            // No quota route: hitting it would throw and fail the test.
            let provider = GeminiProvider(root: root, transport: GeminiRoutingTransport(routes: [
                ":loadCodeAssist": (200, Data(#"{"currentTier":{"id":"free-tier"}}"#.utf8)),
            ]))
            let snapshot = try await provider.fetch()
            #expect(snapshot.plan == "Free")
            #expect(snapshot.primary == nil)
            #expect(snapshot.statusNotes == ["No project provisioned yet — run a Gemini prompt first"])
        }
    }

    @Test func emptyBucketsAddStatusNote() async throws {
        try await withGeminiRoot { root in
            try writeFreshCreds(to: root)
            let provider = GeminiProvider(root: root, transport: GeminiRoutingTransport(routes: [
                ":loadCodeAssist": (200, Data(#"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":"p"}"#.utf8)),
                ":retrieveUserQuota": (200, Data(#"{"buckets":[]}"#.utf8)),
            ]))
            let snapshot = try await provider.fetch()
            #expect(snapshot.primary == nil)
            #expect(snapshot.statusNotes == ["No quota data yet"])
        }
    }

    @Test func sunsetStatusesMapToDataUnavailable() async throws {
        for status in [403, 404] {
            try await withGeminiRoot { root in
                try writeFreshCreds(to: root)
                let provider = GeminiProvider(root: root, transport: GeminiRoutingTransport(routes: [
                    ":loadCodeAssist": (200, Data(#"{"cloudaicompanionProject":"p"}"#.utf8)),
                    ":retrieveUserQuota": (status, Data("{}".utf8)),
                ]))
                await #expect(throws: ProviderFetchError.dataUnavailable(description: "Gemini quota API unavailable for this account")) {
                    _ = try await provider.fetch()
                }
            }
        }
    }

    @Test func unauthorizedRPCStaysUnauthorized() async throws {
        try await withGeminiRoot { root in
            try writeFreshCreds(to: root)
            let provider = GeminiProvider(root: root, transport: GeminiRoutingTransport(routes: [
                ":loadCodeAssist": (401, Data("{}".utf8)),
            ]))
            await #expect(throws: ProviderFetchError.unauthorized) {
                _ = try await provider.fetch()
            }
        }
    }
}
