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
    /// This account's label in jcode's account store (`claude-1`, `claude-2`),
    /// used to find the same account's credentials there when Claude Code's
    /// have gone stale. nil when jcode has no account for this profile.
    let jcodeAccountLabel: String?

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
        jcodeLabels: [String: String] = jcodeAccountLabels()
    ) -> [ClaudeAccount] {
        let primary = ClaudeAccount(
            id: .claude,
            name: "Claude",
            shortCode: "CLA",
            configDir: home.appendingPathComponent(".claude"),
            jcodeAccountLabel: jcodeLabels["claude"] ?? "claude-1"
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
            discovered.append(
                ClaudeAccount(
                    id: .claudeAccount(suffix: suffix),
                    name: "Claude \(suffix.capitalizedFirstLetter)",
                    shortCode: Self.shortCode(for: suffix),
                    configDir: url,
                    jcodeAccountLabel: jcodeLabels[suffix]
                )
            )
        }

        // Stable, deterministic order: the tab bar must not reshuffle between
        // launches because the filesystem returned a different enumeration.
        discovered.sort { $0.configDir.lastPathComponent < $1.configDir.lastPathComponent }
        return [primary] + discovered
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

    /// Maps a config-dir suffix to jcode's account label (`claude-1`,
    /// `claude-2`, ...) using jcode's own account order in `~/.jcode/auth.json`.
    ///
    /// Only the **label and email** are read. That file also holds live OAuth
    /// tokens; nothing here parses, keeps or logs them.
    static func jcodeAccountLabels(
        authFile: URL = AppPaths.home.appendingPathComponent(".jcode/auth.json")
    ) -> [String: String] {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["anthropic_accounts"] as? [[String: Any]]
        else { return [:] }

        // jcode labels accounts claude-1, claude-2, ... in file order, and the
        // first is the primary profile. For the rest, the email's local part is
        // the only available link to a `~/.claude-<suffix>` directory
        // (elara@datainnovation.io -> elara).
        var map: [String: String] = [:]
        for (index, account) in accounts.enumerated() {
            guard let label = account["label"] as? String else { continue }
            let key: String
            if index == 0 {
                key = "claude"
            } else if let email = account["email"] as? String,
                      let local = email.split(separator: "@").first {
                key = String(local).lowercased()
            } else {
                key = "account-\(index)"
            }
            map[key] = label
        }
        return map
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
