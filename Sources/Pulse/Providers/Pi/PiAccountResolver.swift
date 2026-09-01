import CryptoKit
import Foundation

/// Resolves pi's provider keys (`anthropic`, `anthropic-2`, …) to the Anthropic
/// account each one signs in as.
///
/// **Why this exists, and why the obvious shortcut is wrong.** pi names accounts
/// by position in `~/.pi/agent/auth.json` and records nothing else about them:
/// no email, no account id, only the key on each message. The first version of
/// this integration therefore mapped `anthropic` → the primary account and
/// `anthropic-N` → the Nth, on the assumption that the accounts were added in
/// the same order everywhere.
///
/// Measured 2026-09-01 against `api.anthropic.com/api/oauth/profile`, that
/// assumption was **exactly backwards on this machine**:
///
/// ```
/// pi "anthropic"   -> elara@datainnovation.io   (Pulse's Claude Elara tab)
/// pi "anthropic-2" -> joel@datainnovation.io    (Pulse's Claude tab)
/// ```
///
/// 153.4M tokens — effectively all pi usage — were being billed to the wrong
/// tab, and nothing about the numbers looked wrong: they were plausible, they
/// were on a real account, and they added up. Only the account's owner could
/// tell. That is the whole argument for resolving identity instead of guessing
/// order: an ordering assumption fails silently and consistently.
///
/// **How it resolves.** One `GET /api/oauth/profile` per pi key, using the
/// token pi already holds, returning `account.uuid` — the same uuid Claude Code
/// writes into `<configDir>/.claude.json` as `oauthAccount.accountUuid`. Both
/// sides then agree on an identity neither of them made up.
///
/// **Cost control.** The answer is cached on disk keyed by a *fingerprint of
/// the token*, so the call happens once per key and again only when pi signs
/// that key in again (new token ⇒ possibly a different account ⇒ must
/// re-resolve). Pulse never refreshes the token: an expired one is skipped, not
/// rotated, because rotating it would break pi's own session.
///
/// **When it cannot resolve** (offline, expired token, no cache yet), the key's
/// sessions are attributed to **no account at all**. Dropping usage is visible
/// and recoverable; putting it on the wrong account is neither.
actor PiAccountResolver {
    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let authFile: URL
    private let cacheFile: URL
    private let http: HTTPClient
    private var cache: [String: Entry]
    private var loaded = false

    /// One resolved key. `tokenFingerprint` is a SHA-256 prefix over the access
    /// token — never the token — so the cache can detect a re-login without
    /// storing credential material on disk.
    struct Entry: Codable, Sendable, Equatable {
        var tokenFingerprint: String
        var accountUUID: String
        var email: String?
    }

    init(
        authFile: URL = AppPaths.home.appendingPathComponent(".pi/agent/auth.json"),
        cacheName: String = "pi-accounts-v1",
        http: HTTPClient = HTTPClient()
    ) {
        self.authFile = authFile
        self.cacheFile = AppPaths.cacheDirectory.appendingPathComponent("\(cacheName).json")
        self.http = http
        self.cache = [:]
    }

    /// pi provider keys signed in as `accountUUID`.
    ///
    /// Returns an empty set rather than a guess when nothing resolves, so a
    /// provider that cannot identify its pi sessions simply shows none.
    func providerKeys(forAccountUUID accountUUID: String) async -> Set<String> {
        let resolved = await resolveAll()
        return Set(resolved.filter { $0.value.accountUUID == accountUUID }.keys)
    }

    /// Every pi key this resolver could identify, key -> account.
    func resolveAll() async -> [String: Entry] {
        loadCacheIfNeeded()
        let credentials = Self.readAuth(authFile)

        var result: [String: Entry] = [:]
        var changed = false
        for (key, credential) in credentials {
            let fingerprint = Self.fingerprint(credential.accessToken)
            // Cache hit only when the token is the same one we resolved: a new
            // token may be a different account entirely.
            if let cached = cache[key], cached.tokenFingerprint == fingerprint {
                result[key] = cached
                continue
            }
            // Never refresh, never rotate: an expired token is pi's to renew.
            guard !credential.isExpired else { continue }
            guard let profile = await fetchProfile(accessToken: credential.accessToken) else { continue }
            let entry = Entry(
                tokenFingerprint: fingerprint,
                accountUUID: profile.uuid,
                email: profile.email
            )
            cache[key] = entry
            result[key] = entry
            changed = true
        }

        // Keys pi has removed must not linger: a stale entry would keep
        // attributing sessions for an account that signed out.
        let liveKeys = Set(credentials.keys)
        if cache.keys.contains(where: { !liveKeys.contains($0) }) {
            cache = cache.filter { liveKeys.contains($0.key) }
            changed = true
        }
        if changed { persist() }
        return result
    }

    // MARK: - Profile lookup

    private struct Profile: Sendable {
        var uuid: String
        var email: String?
    }

    private func fetchProfile(accessToken: String) async -> Profile? {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ]
        guard let data = try? await http.get(Self.profileEndpoint, headers: headers),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // The payload nests the account, but has been seen flat too; accept both.
        let account = (root["account"] as? [String: Any]) ?? root
        guard let uuid = account["uuid"] as? String else { return nil }
        return Profile(uuid: uuid, email: account["email"] as? String)
    }

    // MARK: - pi's credential store

    struct Credential: Sendable {
        var accessToken: String
        /// Milliseconds since epoch, as pi writes it.
        var expiresAt: Double

        var isExpired: Bool { Date().timeIntervalSince1970 * 1000 >= expiresAt }
    }

    /// Anthropic entries of `~/.pi/agent/auth.json`. Only the access token and
    /// its expiry are read; refresh tokens are never touched, and no token
    /// value ever leaves this type.
    static func readAuth(_ url: URL) -> [String: Credential] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: Credential] = [:]
        for (key, value) in root {
            guard isAnthropicKey(key),
                  let entry = value as? [String: Any],
                  let access = entry["access"] as? String,
                  !access.isEmpty
            else { continue }
            let expires = (entry["expires"] as? Double) ?? 0
            result[key] = Credential(accessToken: access, expiresAt: expires)
        }
        return result
    }

    /// `anthropic`, `anthropic-2`, … but not `anthropic-vertex` or
    /// `openai-codex`: only first-party Anthropic subscriptions bill a Claude
    /// account Pulse tracks.
    static func isAnthropicKey(_ key: String) -> Bool {
        if key == "anthropic" { return true }
        guard key.hasPrefix("anthropic-") else { return false }
        return Int(key.dropFirst("anthropic-".count)) != nil
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Cache

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        cache = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
