import Foundation
import SQLite3

/// Cursor session credentials as read from Cursor's own `state.vscdb`.
/// `accessToken` and `cookieHeader` are secrets — never log or print them.
struct CursorSession: Sendable {
    /// The raw JWT from `cursorAuth/accessToken`. Secret.
    let accessToken: String
    /// JWT `sub` claim, format "auth0|user_…".
    let userSub: String
    let email: String?
    /// e.g. "free", "pro", "pro_plus", "business", "free_trial".
    let membershipType: String?
    /// e.g. "active", "canceled", "trialing".
    let subscriptionStatus: String?

    /// `WorkosCursorSessionToken=<sub>%3A%3A<accessToken>` — the literal `|`
    /// in the sub is accepted by the server; `::` is percent-encoded. Secret.
    var cookieHeader: String {
        CursorAuth.cookieHeader(sub: userSub, accessToken: accessToken)
    }
}

/// Reads Cursor's auth state from
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`,
/// a SQLite key/value store (`ItemTable`). Strictly read-only: the DB is
/// opened in immutable mode so a running Cursor is never locked or disturbed.
///
/// Cursor rotates the stored JWT itself and its `exp` claim is bogus
/// (year 2106), so callers re-read the DB on every fetch and never gate on
/// expiry; real session validity surfaces as a 401 (docs/RESEARCH/cursor.md §4).
enum CursorAuth {
    static var defaultDatabaseURL: URL {
        AppPaths.home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private enum Key {
        static let accessToken = "cursorAuth/accessToken"
        static let cachedEmail = "cursorAuth/cachedEmail"
        static let membershipType = "cursorAuth/stripeMembershipType"
        static let subscriptionStatus = "cursorAuth/stripeSubscriptionStatus"
        static let all = [accessToken, cachedEmail, membershipType, subscriptionStatus]
    }

    /// Cheap probe: DB exists and holds a non-empty access token.
    static func isConnected(databaseURL: URL = defaultDatabaseURL) -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        guard let rows = readValues(keys: [Key.accessToken], databaseURL: databaseURL) else { return false }
        return !unquote(rows[Key.accessToken] ?? "").isEmpty
    }

    /// Reads the session afresh (call on every fetch). Returns nil when the DB
    /// is missing/unreadable, the token row is empty, or the JWT has no `sub`.
    static func loadSession(databaseURL: URL = defaultDatabaseURL) -> CursorSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let rows = readValues(keys: Key.all, databaseURL: databaseURL) else { return nil }

        let accessToken = unquote(rows[Key.accessToken] ?? "")
        guard !accessToken.isEmpty else { return nil }
        guard let sub = JWT.claim("sub", of: accessToken, as: String.self), !sub.isEmpty else { return nil }

        func optional(_ key: String) -> String? {
            guard let raw = rows[key] else { return nil }
            let value = unquote(raw)
            return value.isEmpty ? nil : value
        }

        return CursorSession(
            accessToken: accessToken,
            userSub: sub,
            email: optional(Key.cachedEmail),
            membershipType: optional(Key.membershipType),
            subscriptionStatus: optional(Key.subscriptionStatus)
        )
    }

    // MARK: - Cookie composition

    static func cookieHeader(sub: String, accessToken: String) -> String {
        "WorkosCursorSessionToken=\(sub)%3A%3A\(accessToken)"
    }

    /// Derives the user id from the JWT `sub` claim and composes the session
    /// cookie. Returns nil when the token carries no usable `sub`.
    static func cookieHeader(accessToken: String) -> String? {
        guard let sub = JWT.claim("sub", of: accessToken, as: String.self), !sub.isEmpty else { return nil }
        return cookieHeader(sub: sub, accessToken: accessToken)
    }

    // MARK: - Value normalization

    /// `ItemTable` values are plain strings but occasionally JSON-quoted.
    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// "octocat@example.com" → "oc…@example.com".
    static func maskedEmail(_ email: String?) -> String? {
        guard let email, !email.isEmpty else { return nil }
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else {
            return email.prefix(2) + "…"
        }
        let domain = email[email.index(after: at)...]
        return "\(email[..<at].prefix(2))…@\(domain)"
    }

    /// "free" → "Free", "pro_plus" → "Pro Plus".
    static func planLabel(_ membershipType: String?) -> String? {
        guard let membershipType, !membershipType.isEmpty else { return nil }
        return membershipType
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - SQLite (system C API, read-only immutable)

    /// `SELECT value FROM ItemTable WHERE key = ?` for each key. Opens the DB
    /// via `file:<path>?immutable=1` + `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`
    /// so no locks or WAL side effects touch a running Cursor. Returns nil if
    /// the DB cannot be opened or queried; handles are always closed.
    private static func readValues(keys: [String], databaseURL: URL) -> [String: String]? {
        var db: OpaquePointer?
        let uri = "file:\(uriEscapedPath(databaseURL.path))?immutable=1"
        let opened = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close_v2(db) } // No-op on nil; closes even half-opened handles.
        guard opened == SQLITE_OK, let db else { return nil }

        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { return nil }

        var values: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, key, -1, Self.transientDestructor) == SQLITE_OK else { continue }
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                values[key] = String(cString: text)
            }
        }
        return values
    }

    /// SQLITE_TRANSIENT: makes SQLite copy bound text immediately.
    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// Escapes the characters SQLite's URI parser treats specially. Spaces are
    /// fine unescaped (verified against this machine's "Application Support" path).
    private static func uriEscapedPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
    }
}
