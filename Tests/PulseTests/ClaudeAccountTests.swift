import Foundation
import Testing

@testable import Pulse

/// Claude Code supports any number of accounts via `CLAUDE_CONFIG_DIR`, so the
/// set of providers is discovered from the filesystem rather than declared.
/// These tests pin what counts as an account and what must be ignored.
@Suite("Claude account discovery")
struct ClaudeAccountDiscoveryTests {
    /// Builds a home directory containing the awkward real-world cases.
    private func makeHome() throws -> URL {
        let home = URL.temporaryDirectory.appendingPathComponent("pulse-home-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        func dir(_ name: String, projects: Bool = false, credentials: Bool = false) throws {
            let base = home.appendingPathComponent(name)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            if projects {
                try fm.createDirectory(
                    at: base.appendingPathComponent("projects"),
                    withIntermediateDirectories: true
                )
            }
            if credentials {
                try Data("{}".utf8).write(to: base.appendingPathComponent(".credentials.json"))
            }
        }

        try dir(".claude", projects: true, credentials: true)
        try dir(".claude-elara", projects: true)      // logs only
        try dir(".claude-work", credentials: true)    // credentials only
        try dir(".claude-empty")                      // neither, must be ignored
        try dir(".codex", projects: true)             // unrelated provider
        // Two traps, excluded by two different rules:
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data("x".utf8).write(to: home.appendingPathComponent(".claude-backup.tar"))
        return home
    }

    @Test func findsAccountsAndIgnoresNonAccounts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let accounts = ClaudeAccount.discover(home: home)
        let ids = accounts.map(\.id.rawValue)

        #expect(accounts.first?.id == .claude, "primary is always first")
        #expect(ids.contains("claudeAccount.elara"), "an account with only projects/ counts")
        #expect(ids.contains("claudeAccount.work"), "an account with only credentials counts")
        #expect(!ids.contains("claudeAccount.empty"), "a directory with neither is not an account")
        #expect(!ids.contains { $0.contains("json") }, "~/.claude.json is a file, not an account")
        #expect(!ids.contains { $0.contains("backup") }, "a file matching the prefix is not an account")
        #expect(!ids.contains { $0.contains("codex") }, "unrelated providers are never swept in")
        #expect(accounts.count == 3)
    }

    /// The primary must survive even on a machine where Claude Code was never
    /// set up, or its tab disappears rather than showing "not connected".
    @Test func primarySurvivesAnEmptyHome() throws {
        let home = URL.temporaryDirectory.appendingPathComponent("pulse-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let accounts = ClaudeAccount.discover(home: home)
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == .claude)
    }

    /// The tab bar must not reshuffle between launches.
    @Test func orderIsDeterministic() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = ClaudeAccount.discover(home: home).map(\.id.rawValue)
        let second = ClaudeAccount.discover(home: home).map(\.id.rawValue)
        #expect(first == second)
    }

    /// Account ids are namespaced, so a profile at `~/.claude-codex` cannot
    /// collide with the Codex provider and silently take over its tab.
    @Test func accountIdsAreNamespaced() {
        let collide = ProviderID.claudeAccount(suffix: "codex")
        #expect(collide != .codex)
        #expect(collide.isClaudeAccount)
        #expect(!ProviderID.codex.isClaudeAccount)
        #expect(ProviderID.claude.isClaudeAccount, "the primary is a Claude account too")
    }

    /// Keychain service naming is Claude Code's contract, not ours: the primary
    /// uses the bare service, every other profile appends 8 hex chars of the
    /// SHA-256 of its absolute config path.
    @Test func keychainServiceMatchesClaudeCodesScheme() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accounts = ClaudeAccount.discover(home: home)
        let secondary = try #require(accounts.first { $0.id != .claude })

        #expect(secondary.keychainService.hasPrefix("Claude Code-credentials-"))
        #expect(secondary.keychainService.count == "Claude Code-credentials-".count + 8)

        // Pinned against a value observed in a real Keychain on 2026-08-27, so
        // a change to the hashing input fails here rather than silently
        // reading the wrong account's token.
        let digest = ClaudeAccount.pathDigest(URL(fileURLWithPath: "/Users/joelsbastos/.claude-elara"))
        #expect(digest == "857bc7f5")
    }

    /// Every account needs its own log root and parse cache, or two accounts
    /// report each other's usage.
    @Test func accountsAreFullyIsolated() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accounts = ClaudeAccount.discover(home: home)

        #expect(Set(accounts.map(\.cacheNamespace)).count == accounts.count)
        #expect(Set(accounts.map(\.projectsRoot.path)).count == accounts.count)
        #expect(Set(accounts.map(\.keychainService)).count == accounts.count)
    }

    /// The menu bar stacks a 3-letter code as 2 over 1, so a shorter code
    /// breaks the layout.
    @Test func shortCodesAreAlwaysThreeCharacters() {
        #expect(ClaudeAccount.shortCode(for: "elara").count == 3)
        #expect(ClaudeAccount.shortCode(for: "a").count == 3)
        #expect(ClaudeAccount.shortCode(for: "123").count == 3, "digits only still yields a code")
        #expect(ClaudeAccount.shortCode(for: "").count == 3)
    }
}

@Suite("Provider registry")
struct ProviderRegistryTests {
    /// Discovered accounts sit directly after the primary, ahead of the other
    /// providers, so the Claude tabs stay together.
    @Test func accountsAreSplicedAfterClaude() {
        let elara = ProviderID.claudeAccount(suffix: "elara")
        let work = ProviderID.claudeAccount(suffix: "work")
        ProviderRegistry.shared.register(claudeAccounts: [.claude, elara, work])
        defer { ProviderRegistry.shared.register(claudeAccounts: [.claude]) }

        let order = ProviderID.allCases
        #expect(order.first == .claude)
        let codexIndex = order.firstIndex(of: .codex)
        let elaraIndex = order.firstIndex(of: elara)
        let workIndex = order.firstIndex(of: work)
        #expect(codexIndex != nil)
        #expect(elaraIndex != nil)
        #expect(workIndex != nil)
        if let codexIndex, let elaraIndex, let workIndex {
            #expect(elaraIndex < codexIndex)
            #expect(workIndex < codexIndex)
        }
        #expect(Set(order).count == order.count, "no duplicates")
    }

    @Test func registrationIsIdempotent() {
        let elara = ProviderID.claudeAccount(suffix: "elara")
        ProviderRegistry.shared.register(claudeAccounts: [.claude, elara])
        let first = ProviderID.allCases
        ProviderRegistry.shared.register(claudeAccounts: [.claude, elara])
        defer { ProviderRegistry.shared.register(claudeAccounts: [.claude]) }
        #expect(ProviderID.allCases == first)
    }
}

/// The Usage Breakdown window offers a tab per breakdown-capable provider. Every
/// discovered Claude account is capable, so capability alone is the wrong filter:
/// it showed a tab for accounts the user had switched off, including ones with no
/// projects at all.
@Suite("Breakdown provider selection")
struct BreakdownProviderSelectionTests {
    /// Mirrors `BreakdownViewModel.supportedProviders`.
    private func offered(capable: [ProviderID], enabled: [ProviderID]) -> [ProviderID] {
        let set = Set(enabled)
        return capable.filter(set.contains)
    }

    /// Mirrors the selection fallback in `init` and in `show(initialProvider:)`.
    private func selection(preferred: ProviderID, offered: [ProviderID]) -> ProviderID {
        offered.contains(preferred) ? preferred : (offered.first ?? .claude)
    }

    private let elara = ProviderID.claudeAccount(suffix: "elara")
    private let joeld = ProviderID.claudeAccount(suffix: "joeld")
    private var capable: [ProviderID] { [.claude, elara, joeld, .codex] }

    @Test func disabledAccountsAreNotOffered() {
        let shown = offered(capable: capable, enabled: [.claude, elara, .codex])
        #expect(!shown.contains(joeld), "a disabled account must not get a tab")
        #expect(shown.contains(elara))
        #expect(shown == [.claude, elara, .codex], "canonical order, not enabled order")
    }

    /// The selection is persisted and the window is cached, so a provider
    /// disabled since the last open would otherwise stay selected with no tab.
    @Test func selectionFallsBackOffADisabledProvider() {
        let shown = offered(capable: capable, enabled: [.claude, elara, .codex])
        #expect(selection(preferred: joeld, offered: shown) == .claude)
        #expect(selection(preferred: elara, offered: shown) == elara, "a valid selection is kept")
    }

    @Test func degradesRatherThanCrashingWhenNothingIsEnabled() {
        let none = offered(capable: capable, enabled: [])
        #expect(none.isEmpty)
        #expect(selection(preferred: elara, offered: none) == .claude)
    }
}
