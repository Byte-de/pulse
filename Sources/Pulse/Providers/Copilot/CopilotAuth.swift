import Foundation

/// GitHub Copilot editor credentials under `~/.config/github-copilot`
/// (root injectable for tests). The official copilot-language-server owns two
/// files (docs/RESEARCH/oss-reference.md §D1):
/// - `apps.json` (CURRENT) — keyed `"<host>:<githubAppId>"`, e.g.
///   `"github.com:Iv1.b507a08c87ecfe98"`, value `{user, oauth_token, githubAppId}`.
/// - `hosts.json` (LEGACY) — keyed by the plain host, `"github.com"`. The
///   language server migrates its entries into apps.json (existing apps.json
///   entries win) and then deletes it, so apps.json takes precedence here too.
///
/// The `oauth_token` (`gho_…`/`ghu_…`) is a long-lived GitHub token; Pulse
/// reads it, never rotates it, and never logs it.
enum CopilotAuth {
    /// Decoded github.com entry from either auth file. Every field is
    /// optional — only a non-empty `oauthToken` makes the account usable.
    struct Credentials: Sendable, Equatable {
        /// GitHub OAuth token (`gho_…`) or GitHub App user token (`ghu_…`).
        var oauthToken: String?
        /// GitHub login, e.g. "octocat" — used for the masked account label.
        var user: String?
    }

    static var defaultRoot: URL {
        AppPaths.home.appendingPathComponent(".config/github-copilot", isDirectory: true)
    }

    static func appsURL(root: URL) -> URL { root.appendingPathComponent("apps.json") }
    static func hostsURL(root: URL) -> URL { root.appendingPathComponent("hosts.json") }

    // MARK: - Connection probe (local-only, no network)

    /// Connected iff one of the auth files holds a non-empty github.com
    /// oauth token. apps.json (current) is consulted before hosts.json (legacy).
    static func probe(root: URL, setupHint: String) -> ProviderConnection {
        guard let credentials = load(root: root),
              let token = credentials.oauthToken, !token.isEmpty
        else {
            return .notConnected(hint: setupHint)
        }
        return .available
    }

    /// First file that yields a usable (non-empty-token) github.com entry:
    /// apps.json wins over the legacy hosts.json, mirroring the official
    /// language server's migration semantics.
    static func load(root: URL) -> Credentials? {
        let candidates: [Credentials?] = [
            (try? Data(contentsOf: appsURL(root: root))).flatMap(parseApps),
            (try? Data(contentsOf: hostsURL(root: root))).flatMap(parseHosts),
        ]
        return candidates
            .compactMap { $0 }
            .first { $0.oauthToken?.isEmpty == false }
    }

    // MARK: - Pure parsers (tested)

    /// `apps.json`: entries keyed `"github.com:<clientID>"`. Enterprise hosts
    /// (`"octocorp.ghe.com:…"`) are skipped — Pulse tracks github.com only.
    static func parseApps(_ data: Data) -> Credentials? {
        credentials(in: data) { key in
            key == "github.com" || key.hasPrefix("github.com:")
        }
    }

    /// Legacy `hosts.json`: entries keyed by the plain host, `"github.com"`.
    static func parseHosts(_ data: Data) -> Credentials? {
        credentials(in: data) { key in
            key == "github.com" || key.hasPrefix("github.com:")
        }
    }

    /// Best github.com entry of a JSON object: prefers entries carrying a
    /// non-empty `oauth_token`, scanning keys in sorted order so ties are
    /// deterministic. Nil when the data is not a JSON object or no key matches.
    private static func credentials(
        in data: Data,
        keyMatches: (String) -> Bool
    ) -> Credentials? {
        guard let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var fallback: Credentials?
        for key in rootObject.keys.sorted() where keyMatches(key) {
            guard let entry = rootObject[key] as? [String: Any] else { continue }
            let parsed = Credentials(
                oauthToken: entry["oauth_token"] as? String,
                user: entry["user"] as? String
            )
            if parsed.oauthToken?.isEmpty == false { return parsed }
            if fallback == nil { fallback = parsed }
        }
        return fallback
    }

    /// "first 2 chars + …", e.g. "octocat" → "oc…". Nil for blank input.
    static func maskedUser(_ user: String) -> String? {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(trimmed.prefix(2))…"
    }
}
