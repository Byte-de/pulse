import Foundation
import Testing

@testable import Pulse

/// Claude Code refreshes its OAuth token only when Claude Code runs. Leave it a
/// day and the Keychain item is expired, so Pulse loses the limit gauges even
/// though the account is healthy - and polling the dead token every tick gets
/// the usage endpoint to rate-limit the account, which is worse than showing
/// nothing. jcode refreshes on its own schedule, so its copy of the same
/// account's credentials is usually live.
@Suite("jcode credential fallback")
struct JcodeCredentialsStoreTests {
    private func makeAuthFile(
        _ directory: URL,
        accounts: [(label: String, email: String, token: String, expiresInHours: Double)]
    ) throws -> URL {
        let entries = accounts.map { account in
            let expires = Int((Date.now.timeIntervalSince1970 + account.expiresInHours * 3600) * 1000)
            return """
            {"label":"\(account.label)","email":"\(account.email)",
             "access":"\(account.token)","refresh":"r-\(account.token)",
             "expires":\(expires),"scopes":["user:inference"]}
            """
        }.joined(separator: ",")
        let url = directory.appendingPathComponent("auth.json")
        try Data("""
        {"anthropic_accounts":[\(entries)],"active_anthropic_account":"claude-2"}
        """.utf8).write(to: url)
        return url
    }

    private func tempDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("pulse-jcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsCredentialsByAccountLabel() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeAuthFile(dir, accounts: [
            (label: "claude-1", email: "joel@example.com", token: "tok-one", expiresInHours: 7),
            (label: "claude-2", email: "elara@example.com", token: "tok-two", expiresInHours: 7),
        ])
        let store = JcodeCredentialsStore(authFile: file)

        #expect(store.credentials(forAccountLabel: "claude-1")?.accessToken == "tok-one")
        #expect(store.credentials(forAccountLabel: "claude-2")?.accessToken == "tok-two")
        #expect(store.credentials(forAccountLabel: "claude-9") == nil)
        // `expires` is epoch milliseconds, matching Claude Code's `expiresAt`.
        // Reading it as seconds would make every token look decades stale.
        #expect(store.credentials(forAccountLabel: "claude-1")?.isExpired() == false)
    }

    /// Absence is the normal case for anyone not running jcode, so it must be
    /// silent. Throwing here would turn "you don't use jcode" into an error.
    @Test func missingOrMalformedFilesAreSilent() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let absent = JcodeCredentialsStore(authFile: dir.appendingPathComponent("nope.json"))
        #expect(absent.credentials(forAccountLabel: "claude-1") == nil)
        #expect(!absent.sourceExists)

        let malformed = dir.appendingPathComponent("bad.json")
        try Data("{ not json".utf8).write(to: malformed)
        #expect(JcodeCredentialsStore(authFile: malformed).credentials(forAccountLabel: "claude-1") == nil)

        let empty = dir.appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        #expect(JcodeCredentialsStore(authFile: empty).credentials(forAccountLabel: "claude-1") == nil)
    }

    /// The selection rule, mirroring `ClaudeProvider.loadLimits`. Choosing by
    /// validity rather than a fixed order matters in both directions: never
    /// switching means the gauges stay broken, always switching means Pulse
    /// stops using a perfectly good token.
    @Test func prefersWhicheverStoreHoldsAValidToken() {
        func credentials(_ token: String, expiresInHours: Double) -> ClaudeCredentials {
            ClaudeCredentials(
                accessToken: token,
                expiresAt: (Date.now.timeIntervalSince1970 + expiresInHours * 3600) * 1000,
                subscriptionType: "max",
                rateLimitTier: nil
            )
        }
        func chosen(keychain: ClaudeCredentials?, jcode: ClaudeCredentials?) -> String {
            guard let keychain else {
                guard let jcode, !jcode.isExpired() else { return "none" }
                return "jcode"
            }
            if keychain.isExpired(), let jcode, !jcode.isExpired() { return "jcode" }
            return "keychain"
        }

        let stale = credentials("keychain-stale", expiresInHours: -8)
        let fresh = credentials("jcode-fresh", expiresInHours: 7)

        // The situation that motivated this: observed 2026-08-28, Keychain 8.4h
        // expired while jcode's copy of the same account had 7.7h left.
        #expect(chosen(keychain: stale, jcode: fresh) == "jcode")
        #expect(chosen(keychain: credentials("k", expiresInHours: 5), jcode: fresh) == "keychain")
        // Both dead: keep the Keychain error, which is the one worth showing.
        #expect(chosen(keychain: stale, jcode: credentials("j", expiresInHours: -1)) == "keychain")
        #expect(chosen(keychain: nil, jcode: fresh) == "jcode")
        #expect(chosen(keychain: nil, jcode: credentials("j", expiresInHours: -1)) == "none")
        #expect(chosen(keychain: stale, jcode: nil) == "keychain")
    }

    /// Accounts are mapped to jcode labels by the email's local part, so
    /// `~/.claude-elara` finds `elara@...` = `claude-2`. Hardcoding the pair
    /// would break for any profile named differently.
    @Test func mapsConfigDirectoriesToJcodeLabels() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeAuthFile(dir, accounts: [
            (label: "claude-1", email: "joel@example.com", token: "a", expiresInHours: 1),
            (label: "claude-2", email: "elara@example.com", token: "b", expiresInHours: 1),
        ])

        let labels = ClaudeAccount.jcodeAccountLabels(authFile: file)
        #expect(labels["claude"] == "claude-1", "the first account is the primary profile")
        #expect(labels["elara"] == "claude-2", "later accounts map by email local part")
        #expect(labels["nonexistent"] == nil)
    }
}
