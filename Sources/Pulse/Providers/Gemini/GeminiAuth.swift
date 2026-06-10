import Foundation

/// Gemini CLI auth artifacts under `~/.gemini` (root injectable for tests):
/// - `oauth_creds.json` — Google OAuth credentials; `expiry_date` is epoch
///   MILLISECONDS (gemini-cli convention, not seconds).
/// - `settings.json` — auth type at the NESTED key `security.auth.selectedType`.
/// - `google_accounts.json` — `{active, old[]}`.
///
/// Strictly read-only on all of these: when the stored access token is stale
/// the refresh happens IN MEMORY ONLY via the public gemini-cli OAuth client.
/// Pulse never rewrites `oauth_creds.json` — the CLI owns that file.
actor GeminiAuth {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static let signInAgainHint = "Sign in again with `gemini`"
    static let cliMissingHint = "Open the `gemini` CLI once to refresh the Google session"

    /// Decoded `oauth_creds.json`. Every field is optional — BYOID variants
    /// ("authorized_user", "service_account") carry different subsets.
    struct Credentials: Sendable, Equatable {
        /// Short-lived Bearer token for googleapis.
        var accessToken: String?
        /// Long-lived token — the "connected" signal. Pulse never rotates it.
        var refreshToken: String?
        /// Epoch MILLISECONDS.
        var expiryDateMS: Double?
        /// OIDC JWT carrying `email` + `hd` claims, decoded locally only.
        var idToken: String?

        var expiry: Date? {
            expiryDateMS.map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        /// Whether the stored access token is still usable. Stale once
        /// `expiry_date − 60 s ≤ now` (one minute of safety leeway).
        func isFresh(now: Date = .now) -> Bool {
            guard let accessToken, !accessToken.isEmpty, let expiry else { return false }
            return expiry.addingTimeInterval(-60) > now
        }
    }

    private let root: URL
    private let transport: any GeminiTransport
    private let setupHint: String

    /// In-memory refresh cache — never persisted, never logged.
    private var refreshed: (token: String, expiresAt: Date)?
    /// id_token from the latest refresh response (fresher than the file's).
    private var refreshedIDToken: String?
    /// OAuth client constants extracted from the local gemini-cli install
    /// (discovered once per process; see `GeminiOAuthClientLocator`).
    private var oauthClient: GeminiOAuthClient?

    /// `oauthClient` overrides runtime discovery (tests; never needed in prod).
    init(
        root: URL,
        transport: any GeminiTransport,
        setupHint: String,
        oauthClient: GeminiOAuthClient? = nil
    ) {
        self.root = root
        self.transport = transport
        self.setupHint = setupHint
        self.oauthClient = oauthClient
    }

    private var credsURL: URL { root.appendingPathComponent("oauth_creds.json") }
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }
    private var accountsURL: URL { root.appendingPathComponent("google_accounts.json") }

    // MARK: - Connection probe (local-only, no network)

    /// Connected for quota tracking iff `oauth_creds.json` holds a non-empty
    /// refresh token AND the selected auth type is `oauth-personal` or unset.
    /// API-key/Vertex/Cloud-Shell modes don't expose the personal Code Assist
    /// quota (docs/RESEARCH/gemini.md §6), so they get a specific hint.
    static func probe(root: URL, setupHint: String) -> ProviderConnection {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("oauth_creds.json")),
              let creds = parseCredentials(data),
              let refreshToken = creds.refreshToken, !refreshToken.isEmpty
        else {
            return .notConnected(hint: setupHint)
        }
        let selected = (try? Data(contentsOf: root.appendingPathComponent("settings.json")))
            .flatMap(selectedAuthType(fromSettingsData:))
        if let selected, selected != "oauth-personal" {
            return .notConnected(hint: "Gemini quota tracking needs Google sign-in (oauth-personal)")
        }
        return .available
    }

    // MARK: - Token access

    /// A usable Bearer token: the stored one while fresh, otherwise the cached
    /// in-memory refresh, otherwise a new refresh round-trip.
    /// Drops the in-memory refreshed token so the next `accessToken()` call
    /// does a fresh refresh-token round-trip. Called when Google rejects a
    /// token early (revocation) — otherwise the dead token would be reused
    /// until its natural ~55-minute expiry.
    func invalidate() {
        refreshed = nil
    }

    func accessToken(now: Date = .now) async throws -> String {
        guard let creds = loadCredentials() else {
            throw ProviderFetchError.notLoggedIn(hint: setupHint)
        }
        if creds.isFresh(now: now), let token = creds.accessToken {
            return token
        }
        if let refreshed, refreshed.expiresAt.addingTimeInterval(-60) > now {
            return refreshed.token
        }
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw ProviderFetchError.notLoggedIn(hint: Self.signInAgainHint)
        }
        return try await refresh(refreshToken: refreshToken, now: now)
    }

    private func refresh(refreshToken: String, now: Date) async throws -> String {
        guard let client = oauthClient ?? GeminiOAuthClientLocator.discover() else {
            // Without the CLI's OAuth client we cannot mint tokens ourselves;
            // the CLI refreshes its own session the next time it runs.
            throw ProviderFetchError.notLoggedIn(hint: Self.cliMissingHint)
        }
        oauthClient = client
        let request = Self.refreshRequest(refreshToken: refreshToken, client: client)
        // Transport-level failures surface as ProviderFetchError.network.
        let (status, body) = try await transport.post(request)
        guard (200...299).contains(status) else {
            if Self.oauthErrorCode(from: body) == "invalid_grant" {
                // Refresh token revoked/expired — only re-auth in the CLI helps.
                throw ProviderFetchError.notLoggedIn(hint: Self.signInAgainHint)
            }
            throw ProviderFetchError.http(status: status)
        }

        struct TokenResponse: Decodable {
            var accessToken: String?
            var expiresIn: Double?
            var idToken: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
                case idToken = "id_token"
            }
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: body),
              let token = response.accessToken, !token.isEmpty
        else {
            throw ProviderFetchError.parsing(description: "Google token endpoint returned no access token")
        }
        refreshed = (token, now.addingTimeInterval(response.expiresIn ?? 3300))
        if let idToken = response.idToken, !idToken.isEmpty {
            refreshedIDToken = idToken
        }
        return token
    }

    // MARK: - Account identity

    /// Claims from the OIDC id_token, decoded locally and never sent anywhere.
    /// `hd` (hosted domain) is only present on Google Workspace accounts.
    func idTokenClaims() -> (email: String?, isWorkspace: Bool) {
        let token = refreshedIDToken ?? loadCredentials()?.idToken
        guard let token, !token.isEmpty else { return (nil, false) }
        let email = JWT.claim("email", of: token, as: String.self)
        let hostedDomain = JWT.claim("hd", of: token, as: String.self)
        return (email, hostedDomain?.isEmpty == false)
    }

    /// Masked active account email ("ch…@example.com"): `google_accounts.json`
    /// first, falling back to the id_token's email claim.
    func accountLabel() -> String? {
        struct Accounts: Decodable { var active: String? }
        let active = (try? Data(contentsOf: accountsURL))
            .flatMap { try? JSONDecoder().decode(Accounts.self, from: $0) }?
            .active
        let email = active ?? idTokenClaims().email
        return email.flatMap(Self.maskedEmail)
    }

    private func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: credsURL) else { return nil }
        return Self.parseCredentials(data)
    }

    // MARK: - Pure helpers (tested)

    /// Tolerant decode of `oauth_creds.json`: nil only when the data is not a
    /// JSON object; individual fields may be absent or oddly typed.
    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return Credentials(
            accessToken: rootObject["access_token"] as? String,
            refreshToken: rootObject["refresh_token"] as? String,
            expiryDateMS: (rootObject["expiry_date"] as? Double)
                ?? (rootObject["expiry_date"] as? String).flatMap(Double.init),
            idToken: rootObject["id_token"] as? String
        )
    }

    /// `settings.json` → `security.auth.selectedType`. The key is a nested
    /// object path, NOT a top-level `selectedAuthType`
    /// (gemini-cli settingsSchema.ts:1968-2006). Absent/malformed ⇒ nil.
    static func selectedAuthType(fromSettingsData data: Data) -> String? {
        guard let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let security = rootObject["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let value = auth["selectedType"] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the token-refresh POST. Pure so tests can assert the exact wire
    /// format without a live call.
    static func refreshRequest(refreshToken: String, client: GeminiOAuthClient) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(refreshRequestBody(refreshToken: refreshToken, client: client).utf8)
        return request
    }

    static func refreshRequestBody(refreshToken: String, client: GeminiOAuthClient) -> String {
        formEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
        ])
    }

    /// application/x-www-form-urlencoded keeping RFC 3986 unreserved
    /// characters literal (refresh tokens contain `/` and `+`, which must be
    /// percent-escaped).
    static func formEncode(_ fields: [(name: String, value: String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ string: String) -> String {
            string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        }
        return fields.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
    }

    /// OAuth error code from a token-endpoint failure body, e.g.
    /// `{"error":"invalid_grant", "error_description":…}`.
    static func oauthErrorCode(from body: Data) -> String? {
        let rootObject = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return rootObject?["error"] as? String
    }

    /// "first 2 chars + …@ + domain"; nil when the input isn't email-shaped.
    static func maskedEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return nil }
        let domain = trimmed[trimmed.index(after: at)...]
        guard !domain.isEmpty else { return nil }
        return "\(trimmed[..<at].prefix(2))…@\(domain)"
    }
}
