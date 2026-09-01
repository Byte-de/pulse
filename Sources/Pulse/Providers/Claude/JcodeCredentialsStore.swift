import Foundation

/// Claude OAuth credentials as jcode stores them, in `~/.jcode/auth.json`.
///
/// **Why Pulse reads a second store.** Claude Code only refreshes its token
/// when you run Claude Code. Leave it for a day and the Keychain item is
/// expired, so Pulse loses the limit gauges even though the account is fine -
/// and polling the dead token gets the usage endpoint to rate-limit the
/// account, which is worse than showing nothing. jcode refreshes on its own
/// schedule, so its copy of the *same* account's credentials is usually live.
/// Observed 2026-08-28: Keychain tokens 8.4h expired while jcode's were 7.7h
/// from expiry, both for the same account.
///
/// Pulse still never refreshes anything. It picks whichever store currently
/// holds a valid token and reads it.
///
/// ```
/// {"anthropic_accounts": [{"label": "claude-1", "email": "...",
///                          "access": "...", "refresh": "...",
///                          "expires": 1787875200000, "scopes": [...]}],
///  "active_anthropic_account": "claude-2"}
/// ```
struct JcodeCredentialsStore: Sendable {
    let authFile: URL

    init(authFile: URL = AppPaths.home.appendingPathComponent(".jcode/auth.json")) {
        self.authFile = authFile
    }

    /// Credentials jcode holds for `accountLabel` (`claude-1`, `claude-2`),
    /// or nil when the file, the account or the token is absent.
    ///
    /// Deliberately returns nil rather than throwing: this is a *fallback*
    /// source, and its absence is the normal case for anyone not running
    /// jcode. A throw here would turn "you don't use jcode" into an error.
    func credentials(forAccountLabel accountLabel: String) -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["anthropic_accounts"] as? [[String: Any]]
        else { return nil }

        guard let account = accounts.first(where: { $0["label"] as? String == accountLabel }),
              let access = account["access"] as? String, !access.isEmpty
        else { return nil }

        // `expires` is epoch MILLISECONDS, matching Claude Code's `expiresAt`.
        let expires = (account["expires"] as? NSNumber)?.doubleValue

        return ClaudeCredentials(
            accessToken: access,
            expiresAt: expires,
            // jcode's auth file records no plan, so the plan label continues to
            // come from the Keychain copy when one exists.
            subscriptionType: nil,
            rateLimitTier: nil
        )
    }

    /// Credentials for the account signed in as `email`. Preferred over the
    /// label lookup: jcode renames labels (`claude-1` -> `claude-otter`,
    /// observed 2026-09-01) and a renamed label matches nothing.
    func credentials(forEmail email: String) -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["anthropic_accounts"] as? [[String: Any]],
              let account = accounts.first(where: {
                  ($0["email"] as? String)?.caseInsensitiveCompare(email) == .orderedSame
              }),
              let access = account["access"] as? String, !access.isEmpty
        else { return nil }
        return ClaudeCredentials(
            accessToken: access,
            expiresAt: (account["expires"] as? NSNumber)?.doubleValue,
            subscriptionType: nil,
            rateLimitTier: nil
        )
    }

    /// Whether the file exists at all, for the connection probe.
    var sourceExists: Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }
}
