import Foundation

/// GitHub Copilot internal user/quota API — the same RPC the official editor
/// plugins call on sign-in (docs/RESEARCH/oss-reference.md §D2-D4). One GET
/// returns plan, quota snapshots, and the monthly reset date.
struct CopilotAPI: Sendable {
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    /// Editor identification headers exactly as CodexBar sends them
    /// (CopilotUsageFetcher.swift:132-138); GitHub rejects unidentified
    /// clients. The token goes on `Authorization: token …` — NOT `Bearer`.
    static func headers(token: String) -> [String: String] {
        [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ]
    }

    private let http: HTTPClient

    init(http: HTTPClient) {
        self.http = http
    }

    /// HTTPClient maps 401/403 → `.unauthorized` and transport failures →
    /// `.network`; the provider maps `.unauthorized` onward to `.notLoggedIn`.
    func fetchUsage(token: String) async throws -> UsageResponse {
        let data = try await http.get(Self.usageURL, headers: Self.headers(token: token))
        return Self.parseUsage(data)
    }

    // MARK: - Response shapes

    /// One entry of `quota_snapshots` (schema: vscode-copilot-chat
    /// chatQuotaService.ts:13-43). Every field optional; numbers tolerated as
    /// Int or Double (GitHub has shipped both).
    struct QuotaSnapshot: Sendable, Equatable {
        var unlimited: Bool?
        /// Monthly allowance, e.g. 300 premium requests on Pro.
        var entitlement: Double?
        /// Requests left this cycle (can go negative with overage).
        var remaining: Double?
        /// Percent REMAINING, 0…100 (negative when over quota).
        var percentRemaining: Double?
        var overagePermitted: Bool?

        init(
            unlimited: Bool? = nil,
            entitlement: Double? = nil,
            remaining: Double? = nil,
            percentRemaining: Double? = nil,
            overagePermitted: Bool? = nil
        ) {
            self.unlimited = unlimited
            self.entitlement = entitlement
            self.remaining = remaining
            self.percentRemaining = percentRemaining
            self.overagePermitted = overagePermitted
        }
    }

    /// `GET /copilot_internal/user`, reduced to the fields Pulse renders.
    struct UsageResponse: Sendable, Equatable {
        /// Raw plan id: "free" | "individual" | "individual_pro" | "business" | "enterprise".
        var copilotPlan: String?
        /// Plain calendar date "yyyy-MM-dd" — the monthly allowance reset day.
        var quotaResetDate: String?
        var premiumInteractions: QuotaSnapshot?
        var chat: QuotaSnapshot?
        var completions: QuotaSnapshot?

        init(
            copilotPlan: String? = nil,
            quotaResetDate: String? = nil,
            premiumInteractions: QuotaSnapshot? = nil,
            chat: QuotaSnapshot? = nil,
            completions: QuotaSnapshot? = nil
        ) {
            self.copilotPlan = copilotPlan
            self.quotaResetDate = quotaResetDate
            self.premiumInteractions = premiumInteractions
            self.chat = chat
            self.completions = completions
        }
    }

    // MARK: - Tolerant parsing (pure, tested)

    /// Field-by-field tolerant parse: a missing or oddly-typed field never
    /// sinks the response, garbage yields an empty response (the snapshot
    /// assembly then surfaces an honest status note instead of failing).
    static func parseUsage(_ data: Data) -> UsageResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return UsageResponse()
        }
        let snapshots = root["quota_snapshots"] as? [String: Any]
        return UsageResponse(
            copilotPlan: nonEmptyString(root["copilot_plan"]),
            quotaResetDate: nonEmptyString(root["quota_reset_date"]),
            premiumInteractions: (snapshots?["premium_interactions"]).flatMap(parseSnapshot),
            chat: (snapshots?["chat"]).flatMap(parseSnapshot),
            completions: (snapshots?["completions"]).flatMap(parseSnapshot)
        )
    }

    static func parseSnapshot(_ value: Any) -> QuotaSnapshot? {
        guard let dict = value as? [String: Any] else { return nil }
        return QuotaSnapshot(
            unlimited: dict["unlimited"] as? Bool,
            entitlement: number(dict["entitlement"]),
            remaining: number(dict["remaining"]),
            percentRemaining: number(dict["percent_remaining"]),
            overagePermitted: dict["overage_permitted"] as? Bool
        )
    }

    /// Int, Double, or numeric String → Double (CodexBar tolerates all three;
    /// JSONSerialization bridges JSON integers to NSNumber, so `as? Double`
    /// already covers Int — the String lane is the extra safety net).
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            // Reject booleans bridged into NSNumber (true would become 1.0).
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // MARK: - Derivation (pure, tested)

    /// Percent USED, clamped 0…100: `100 − percent_remaining`, falling back
    /// to `(entitlement − remaining) / entitlement × 100` when the percent is
    /// missing. Nil when neither lane is derivable (or for unlimited quotas).
    static func utilization(of snapshot: QuotaSnapshot) -> Double? {
        if snapshot.unlimited == true { return nil }
        if let percentRemaining = snapshot.percentRemaining {
            return min(100, max(0, 100 - percentRemaining))
        }
        if let entitlement = snapshot.entitlement, entitlement > 0,
           let remaining = snapshot.remaining {
            return min(100, max(0, (entitlement - remaining) / entitlement * 100))
        }
        return nil
    }

    /// "<used> of <entitlement> requests" with whole numbers (e.g.
    /// "63 of 300 requests"); nil when the counts aren't both known.
    static func detail(for snapshot: QuotaSnapshot) -> String? {
        guard let entitlement = snapshot.entitlement,
              let remaining = snapshot.remaining
        else { return nil }
        let used = max(0, entitlement - remaining)
        return "\(Int(used.rounded())) of \(Int(entitlement.rounded())) requests"
    }

    /// `quota_reset_date` is a plain "yyyy-MM-dd" with no time or zone
    /// (docs/RESEARCH/oss-reference.md §D4) — treat it as the start of that
    /// LOCAL calendar day, not midnight UTC.
    static func parseResetDate(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Raw plan id prettified without inventing marketing names:
    /// "individual" → "Individual", "individual_pro" → "Individual Pro".
    static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
