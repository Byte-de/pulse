import Foundation

/// Cursor dashboard endpoints (docs/RESEARCH/cursor.md). All requests carry the
/// session cookie; POSTs additionally REQUIRE `Origin: https://cursor.com`
/// (verified 403 without). The web app returns its SPA HTML with HTTP 200 for
/// unknown paths, so JSON responses are detected before decoding.
struct CursorAPI: Sendable {
    static let base = URL(string: "https://cursor.com")!
    private static let userAgent = "Pulse/1.0"

    var http: HTTPClient

    // MARK: - Endpoints

    func legacyUsage(session: CursorSession) async throws -> CursorLegacyUsage? {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("api/usage"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "user", value: session.userSub)]
        let data = try await http.get(components.url!, headers: headers(session))
        return Self.decodeJSONOnly(CursorLegacyUsage.self, from: data)
    }

    /// Modern plan summary. Not guaranteed to exist for every account — callers
    /// treat nil as "fall back to the legacy gauge".
    func usageSummary(session: CursorSession) async throws -> CursorUsageSummary? {
        let url = Self.base.appendingPathComponent("api/usage-summary")
        let data = try await http.get(url, headers: headers(session))
        return Self.decodeJSONOnly(CursorUsageSummary.self, from: data)
    }

    func hardLimit(session: CursorSession) async throws -> CursorHardLimit? {
        let data = try await post(path: "api/dashboard/get-hard-limit", body: [:], session: session)
        return Self.decodeJSONOnly(CursorHardLimit.self, from: data)
    }

    /// `month` is 0-BASED (June = 5) — verified against this account.
    func monthlyInvoice(session: CursorSession, now: Date = .now) async throws -> CursorMonthlyInvoice? {
        let components = Calendar.current.dateComponents([.year, .month], from: now)
        let body: [String: Any] = [
            "month": (components.month ?? 1) - 1,
            "year": components.year ?? 2026,
            "includeUsageEvents": false,
        ]
        let data = try await post(path: "api/dashboard/get-monthly-invoice", body: body, session: session)
        return Self.decodeJSONOnly(CursorMonthlyInvoice.self, from: data)
    }

    /// Current-month per-model totals. The window must stay ≤ ~30 days — the
    /// backend 400s on ranges crossing old shard boundaries.
    func aggregatedUsage(
        session: CursorSession,
        from start: Date,
        to end: Date
    ) async throws -> CursorAggregatedUsage? {
        let body: [String: Any] = [
            "teamId": 0,
            "startDate": String(Int64(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int64(end.timeIntervalSince1970 * 1000)),
        ]
        let data = try await post(path: "api/dashboard/get-aggregated-usage-events", body: body, session: session)
        return Self.decodeJSONOnly(CursorAggregatedUsage.self, from: data)
    }

    /// Pages through the event log (newest first) until the window is fully
    /// covered. Heavy accounts easily exceed one page over 30 days; without
    /// pagination every derived chart would silently undercount.
    func filteredEvents(
        session: CursorSession,
        from start: Date,
        to end: Date,
        pageSize: Int = 500,
        maxPages: Int = 20
    ) async throws -> CursorFilteredEvents? {
        var merged: CursorFilteredEvents?
        var collected: [CursorFilteredEvents.Event] = []

        for page in 1...max(1, maxPages) {
            let body: [String: Any] = [
                "teamId": 0,
                "startDate": String(Int64(start.timeIntervalSince1970 * 1000)),
                "endDate": String(Int64(end.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": pageSize,
            ]
            let data = try await post(path: "api/dashboard/get-filtered-usage-events", body: body, session: session)
            guard let response = Self.decodeJSONOnly(CursorFilteredEvents.self, from: data) else {
                break
            }
            let events = response.usageEventsDisplay ?? []
            collected.append(contentsOf: events)
            merged = response

            let total = response.totalUsageEventsCount ?? Int.max
            if events.count < pageSize || collected.count >= total {
                break
            }
        }

        guard var result = merged else { return nil }
        result.usageEventsDisplay = collected
        return result
    }

    // MARK: - Plumbing

    private func headers(_ session: CursorSession) -> [String: String] {
        [
            "Cookie": session.cookieHeader,
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
        ]
    }

    private func post(path: String, body: [String: Any], session: CursorSession) async throws -> Data {
        var headers = headers(session)
        headers["Origin"] = "https://cursor.com"
        let json = try JSONSerialization.data(withJSONObject: body)
        return try await http.post(Self.base.appendingPathComponent(path), headers: headers, jsonBody: json)
    }

    /// Unknown dashboard paths come back as the SPA's HTML at HTTP 200; only
    /// payloads that start with a JSON token are decoded.
    static func decodeJSONOnly<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
              first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
