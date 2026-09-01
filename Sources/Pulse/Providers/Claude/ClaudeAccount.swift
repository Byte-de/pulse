import CryptoKit
import Foundation

/// One Claude Code account (profile) Pulse can track.
///
/// Claude Code supports multiple accounts via `CLAUDE_CONFIG_DIR`: each gets
/// its own config directory (`~/.claude`, `~/.claude-elara`, …) holding that
/// account's `projects/` logs, and its own Keychain item holding its OAuth
/// token.
///
/// **Keychain naming (verified 2026-08-27, `security dump-keychain`):** the
/// default profile stores `Claude Code-credentials`; every other profile
/// stores `Claude Code-credentials-<prefix>`, where `<prefix>` is the first 8
/// hex characters of the SHA-256 of the config directory's **absolute** path.
/// `/Users/joelsbastos/.claude-elara` therefore resolves to `…-857bc7f5`.
/// Deriving beats hard-coding: the same code finds any future profile. Note the
/// path must be absolute and unexpanded `~` does not work - hashing
/// `~/.claude-elara` yields `a6748b75`, which matches nothing.
struct ClaudeAccount: Sendable, Equatable {
    let id: ProviderID
    /// Display name in the tab bar / panel header.
    let name: String
    /// Three-letter menu-bar code.
    let shortCode: String
    /// Config dir, e.g. `~/.claude-elara`.
    let configDir: URL
    /// Every label jcode may write for this account in a session file.
    ///
    /// A **set**, because jcode's two halves disagree with each other:
    /// `~/.jcode/auth.json` renamed the accounts to `claude-otter` /
    /// `claude-fox` while the session writer kept stamping the original
    /// `claude-1` / `claude-2` into `token_usage.account_label` — verified
    /// 2026-09-01 on files written in the same hour as the rename. Matching a
    /// single label therefore drops **all** jcode usage the moment the user
    /// renames an account, which is exactly what happened here: the Claude tab
    /// went to zero tokens with no error anywhere.
    let jcodeAccountLabels: Set<String>
    /// Anthropic's own account id, read from `<configDir>/.claude.json`
    /// (`oauthAccount.accountUuid`). This is the only identifier that is the
    /// same on both sides of a harness boundary — the same uuid comes back from
    /// `/api/oauth/profile` for a pi token — so it, not a directory name or a
    /// position in a file, is what attributes a harness session to an account.
    let accountUUID: String?
    /// Signed-in email from the same file, for display and diagnostics only.
    let email: String?

    var projectsRoot: URL { configDir.appendingPathComponent("projects") }
    var credentialsFile: URL { configDir.appendingPathComponent(".credentials.json") }

    /// Per-account on-disk parse cache; two accounts must never share one.
    var cacheNamespace: String { id.rawValue }

    /// Keychain service for this account's OAuth token.
    var keychainService: String {
        let base = ClaudeCredentials.keychainService
        guard configDir.standardizedFileURL != Self.defaultConfigDir.standardizedFileURL else {
            return base
        }
        return "\(base)-\(Self.pathDigest(configDir))"
    }

    static var defaultConfigDir: URL {
        AppPaths.home.appendingPathComponent(".claude")
    }

    /// First 8 hex chars of SHA-256 over the directory's absolute path.
    static func pathDigest(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Discovery

    /// Every Claude Code account on this machine, primary first.
    ///
    /// Scans the home directory for `.claude` and `.claude-*` **directories**.
    /// Three filters matter, each for a case seen on a real machine:
    ///
    /// 1. **Directories only.** `~/.claude.json` sits right next to them and is
    ///    a settings file, not an account.
    /// 2. **Must look like a config dir**, i.e. contain `projects/` or
    ///    `.credentials.json`. Backup and scratch copies (`.claude-bak`,
    ///    `.claude-old`) otherwise appear as phantom accounts the user has to
    ///    turn off by hand.
    /// 3. **The primary is always included**, even when absent, so the tab does
    ///    not silently vanish on a machine where Claude Code is not set up yet.
    static func discover(
        home: URL = AppPaths.home,
        fileManager: FileManager = .default,
        jcodeAccounts: [JcodeAccountRef] = jcodeAccountRefs()
    ) -> [ClaudeAccount] {
        let primaryDir = home.appendingPathComponent(".claude")
        let primaryIdentity = oauthIdentity(configDir: primaryDir)
        let primary = ClaudeAccount(
            id: .claude,
            name: "Claude",
            shortCode: "CLA",
            configDir: primaryDir,
            jcodeAccountLabels: labels(in: jcodeAccounts, forEmail: primaryIdentity?.email, isPrimary: true),
            accountUUID: primaryIdentity?.uuid,
            email: primaryIdentity?.email
        )

        // NOT `.skipsHiddenFiles`: every Claude config dir starts with a dot,
        // so that option finds exactly zero accounts. Subdirectories are
        // skipped instead, since only the top level of home is of interest.
        let contents = (try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        var discovered: [ClaudeAccount] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(".claude-") else { continue }
            guard isConfigDirectory(url, fileManager: fileManager) else { continue }

            let suffix = String(name.dropFirst(".claude-".count))
            guard !suffix.isEmpty else { continue }
            let identity = oauthIdentity(configDir: url)
            discovered.append(
                ClaudeAccount(
                    id: .claudeAccount(suffix: suffix),
                    name: "Claude \(suffix.capitalizedFirstLetter)",
                    shortCode: Self.shortCode(for: suffix),
                    configDir: url,
                    jcodeAccountLabels: labels(in: jcodeAccounts, forEmail: identity?.email, isPrimary: false),
                    accountUUID: identity?.uuid,
                    email: identity?.email
                )
            )
        }

        // Stable, deterministic order: the tab bar must not reshuffle between
        // launches because the filesystem returned a different enumeration.
        discovered.sort { $0.configDir.lastPathComponent < $1.configDir.lastPathComponent }

        // Two config dirs can hold the *same* Anthropic account (this machine
        // has `~/.claude` and `~/.claude-joeld`, both joel@, same uuid). A
        // harness session names an account, not a directory, so without this
        // its tokens would be counted once per directory. First wins, and the
        // primary is first, so the duplicate keeps its own Claude Code logs and
        // simply claims no harness usage.
        var claimed: Set<String> = []
        return ([primary] + discovered).map { account in
            guard let uuid = account.accountUUID else { return account }
            guard claimed.insert(uuid).inserted else { return account.withoutHarnessClaim() }
            return account
        }
    }

    /// A copy that owns no harness usage, for a duplicate of an account another
    /// config dir already claims.
    func withoutHarnessClaim() -> ClaudeAccount {
        ClaudeAccount(
            id: id,
            name: name,
            shortCode: shortCode,
            configDir: configDir,
            jcodeAccountLabels: [],
            accountUUID: nil,
            email: email
        )
    }

    /// `oauthAccount` as Claude Code writes it into the config dir. Read-only,
    /// and only these two fields: the file also holds project history.
    static func oauthIdentity(configDir: URL) -> (uuid: String, email: String?)? {
        let url = configDir.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String
        else { return nil }
        return (uuid, account["emailAddress"] as? String)
    }

    /// A real Claude config dir has the logs or the credentials; a backup copy
    /// of one may too, so this is a heuristic that errs toward showing an
    /// account (the user can disable it) rather than hiding a real one.
    private static func isConfigDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        let projects = url.appendingPathComponent("projects")
        var projectsIsDir: ObjCBool = false
        let hasProjects = fileManager.fileExists(atPath: projects.path, isDirectory: &projectsIsDir)
            && projectsIsDir.boolValue
        let hasCredentials = fileManager.fileExists(
            atPath: url.appendingPathComponent(".credentials.json").path
        )
        return hasProjects || hasCredentials
    }

    /// Three-letter menu bar code from the profile suffix, uppercased. Falls
    /// back to padding so the two-over-one menu bar layout always has glyphs.
    static func shortCode(for suffix: String) -> String {
        let letters = suffix.filter(\.isLetter).uppercased()
        guard !letters.isEmpty else { return "CLA" }
        return String(letters.prefix(3)).padding(toLength: 3, withPad: "·", startingAt: 0)
    }

    // MARK: - jcode account mapping

    /// One account as jcode's auth file describes it.
    struct JcodeAccountRef: Sendable, Equatable {
        var label: String
        var email: String?
        /// Position in `anthropic_accounts`, which is what the legacy
        /// `claude-N` labels counted.
        var index: Int
    }

    /// jcode's accounts, in file order. Only the label and email are read; the
    /// same file holds live OAuth tokens, which are never parsed or logged here.
    static func jcodeAccountRefs(
        authFile: URL = AppPaths.home.appendingPathComponent(".jcode/auth.json")
    ) -> [JcodeAccountRef] {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["anthropic_accounts"] as? [[String: Any]]
        else { return [] }
        return accounts.enumerated().compactMap { index, account in
            guard let label = account["label"] as? String else { return nil }
            return JcodeAccountRef(label: label, email: account["email"] as? String, index: index)
        }
    }

    /// Labels that may name `email` in a jcode session file: the account's
    /// current label, plus the `claude-N` its position originally earned.
    ///
    /// Matching is by **email**, not by directory name. The old code inferred
    /// the account from the config dir's suffix (`~/.claude-elara` →
    /// `elara@…`), which only worked while the user happened to name the
    /// directory after the mailbox.
    ///
    /// The `claude-N` fallback is the one ordinal assumption left in the
    /// codebase, and it is here because jcode's session writer still emits it:
    /// entries with **no** label at all (8,074 of the last 400 files' entries)
    /// are parsed as `claude-1`, so the first account has to answer to it.
    static func labels(in accounts: [JcodeAccountRef], forEmail email: String?, isPrimary: Bool) -> Set<String> {
        let matches = accounts.filter { ref in
            guard let email, let refEmail = ref.email else { return false }
            return refEmail.caseInsensitiveCompare(email) == .orderedSame
        }
        if matches.isEmpty {
            // jcode not installed, or an account it has never seen. The primary
            // still answers to the legacy label so a machine without jcode
            // emails keeps the behaviour it had.
            return isPrimary && accounts.isEmpty ? ["claude-1"] : []
        }
        var labels = Set(matches.map(\.label))
        for match in matches { labels.insert("claude-\(match.index + 1)") }
        return labels
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
