import Foundation

/// The two Codex rate-limit gauges, shared by the live endpoint and the
/// session-log fallback so both produce identical `LimitWindow` identities.
enum CodexLimitWindows {
    static func fiveHour(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval?) -> LimitWindow {
        LimitWindow(
            id: "five_hour",
            title: "5-Hour Session",
            systemImage: "clock",
            utilization: utilization,
            resetsAt: resetsAt,
            windowDuration: windowDuration
        )
    }

    static func weekly(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval?) -> LimitWindow {
        LimitWindow(
            id: "weekly",
            title: "Weekly Limit",
            systemImage: "calendar",
            utilization: utilization,
            resetsAt: resetsAt,
            windowDuration: windowDuration
        )
    }
}

/// Live rate-limit windows from `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// Headers per docs/RESEARCH/codex.md §4 — the `originator: codex_cli_rs` header
/// plus a CLI-style User-Agent are what get the request past Cloudflare; without
/// them the same Bearer token returns a 403 challenge page.
struct CodexUsageAPI: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// CLI-style UA, e.g. "codex_cli_rs/0.137.0 (Mac OS 26.5.1; arm64) Pulse.app".
    static let userAgent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "codex_cli_rs/0.137.0 (Mac OS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(arch)) Pulse.app"
    }()

    var http: HTTPClient

    func fetchUsage(auth: CodexAuth) async throws -> CodexUsageResponse {
        var headers: [String: String] = [
            "Authorization": "Bearer \(auth.accessToken)",
            "originator": "codex_cli_rs",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]
        if let accountID = auth.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let data = try await http.get(Self.endpoint, headers: headers)
        return try HTTPClient.decode(CodexUsageResponse.self, from: data)
    }

    /// Maps the response windows: primary → 5h session, secondary → weekly.
    /// `reset_at` (unix seconds) wins over the relative `reset_after_seconds`.
    static func limitWindows(
        from response: CodexUsageResponse,
        now: Date = .now
    ) -> (primary: LimitWindow?, secondary: LimitWindow?) {
        let primary = resolve(response.rateLimit?.primaryWindow, now: now).map {
            CodexLimitWindows.fiveHour(utilization: $0.used, resetsAt: $0.resetsAt, windowDuration: $0.duration)
        }
        let secondary = resolve(response.rateLimit?.secondaryWindow, now: now).map {
            CodexLimitWindows.weekly(utilization: $0.used, resetsAt: $0.resetsAt, windowDuration: $0.duration)
        }
        return (primary, secondary)
    }

    /// "Credits: 12.50" when the account has a finite credit balance.
    static func creditsNote(from response: CodexUsageResponse) -> String? {
        guard let credits = response.credits,
              credits.hasCredits == true,
              credits.unlimited != true,
              let balance = credits.balance
        else { return nil }
        return "Credits: \(formattedBalance(balance))"
    }

    private static func resolve(
        _ window: CodexUsageResponse.Window?,
        now: Date
    ) -> (used: Double, resetsAt: Date?, duration: TimeInterval?)? {
        guard let window, let used = window.usedPercent else { return nil }
        var resetsAt: Date?
        if let epochSeconds = window.resetAt {
            resetsAt = Date(timeIntervalSince1970: epochSeconds)
        } else if let after = window.resetAfterSeconds {
            resetsAt = now.addingTimeInterval(after)
        }
        return (used, resetsAt, window.limitWindowSeconds)
    }

    private static func formattedBalance(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}

/// Tolerant decode of the wham/usage payload (docs/RESEARCH/codex.md §4):
/// every field is optional, numbers may arrive as ints, doubles, or strings,
/// and a malformed sub-object never drops its siblings.
struct CodexUsageResponse: Sendable, Equatable {
    var planType: String?
    var rateLimit: RateLimit?
    var credits: Credits?

    struct RateLimit: Sendable, Equatable {
        var primaryWindow: Window?
        var secondaryWindow: Window?
    }

    struct Window: Sendable, Equatable {
        var usedPercent: Double?
        var limitWindowSeconds: Double?
        var resetAfterSeconds: Double?
        /// Unix epoch seconds.
        var resetAt: Double?
    }

    struct Credits: Sendable, Equatable {
        var hasCredits: Bool?
        var unlimited: Bool?
        /// The API sends a string (e.g. "0"); numeric payloads are normalized.
        var balance: String?
    }
}

extension CodexUsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = ((try? container.decodeIfPresent(String.self, forKey: .planType)) ?? nil)
        rateLimit = ((try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)) ?? nil)
        credits = ((try? container.decodeIfPresent(Credits.self, forKey: .credits)) ?? nil)
    }
}

extension CodexUsageResponse.RateLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = ((try? container.decodeIfPresent(CodexUsageResponse.Window.self, forKey: .primaryWindow)) ?? nil)
        secondaryWindow = ((try? container.decodeIfPresent(CodexUsageResponse.Window.self, forKey: .secondaryWindow)) ?? nil)
    }
}

extension CodexUsageResponse.Window: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = Self.flexibleNumber(container, .usedPercent)
        limitWindowSeconds = Self.flexibleNumber(container, .limitWindowSeconds)
        resetAfterSeconds = Self.flexibleNumber(container, .resetAfterSeconds)
        resetAt = Self.flexibleNumber(container, .resetAt)
    }

    private static func flexibleNumber(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let number = ((try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil) {
            return number
        }
        if let string = ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) {
            return Double(string)
        }
        return nil
    }
}

extension CodexUsageResponse.Credits: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = ((try? container.decodeIfPresent(Bool.self, forKey: .hasCredits)) ?? nil)
        unlimited = ((try? container.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? nil)
        if let string = ((try? container.decodeIfPresent(String.self, forKey: .balance)) ?? nil) {
            balance = string
        } else if let number = ((try? container.decodeIfPresent(Double.self, forKey: .balance)) ?? nil) {
            balance = number == number.rounded() ? String(Int(number)) : String(number)
        }
    }
}
