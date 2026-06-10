import Foundation

/// The endpoint behind Claude Code's `/usage` view.
///
/// The response is a flat object whose keys are rate-limit windows
/// (`five_hour`, `seven_day`, `seven_day_opus`, …) — the key set is
/// feature-flagged and grows over time, so decoding iterates keys dynamically
/// and keeps anything shaped like `{utilization, resets_at}`.
struct ClaudeUsageAPI: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var http: HTTPClient

    func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
            "Accept": "application/json",
        ]
        let data = try await http.get(Self.endpoint, headers: headers)
        return try ClaudeUsageResponse.parse(data)
    }

    static func limitWindows(
        from response: ClaudeUsageResponse
    ) -> (primary: LimitWindow?, secondary: LimitWindow?, extras: [LimitWindow]) {
        let primary = response.windows["five_hour"].map {
            LimitWindow(
                id: "five_hour",
                title: "5-Hour Session",
                systemImage: "clock",
                utilization: $0.utilization,
                resetsAt: $0.resetsAt,
                windowDuration: 5 * 3600
            )
        }
        let secondary = response.windows["seven_day"].map {
            LimitWindow(
                id: "seven_day",
                title: "Weekly Limit",
                systemImage: "calendar",
                utilization: $0.utilization,
                resetsAt: $0.resetsAt,
                windowDuration: 7 * 86400
            )
        }

        // Per-model weekly caps, shown only once they carry signal.
        var extras: [LimitWindow] = []
        let perModel: [(key: String, title: String)] = [
            ("seven_day_opus", "Opus Weekly"),
            ("seven_day_sonnet", "Sonnet Weekly"),
        ]
        for (key, title) in perModel {
            guard let window = response.windows[key], window.utilization > 0 else { continue }
            extras.append(
                LimitWindow(
                    id: key,
                    title: title,
                    systemImage: "sparkles",
                    utilization: window.utilization,
                    resetsAt: window.resetsAt,
                    windowDuration: 7 * 86400
                )
            )
        }
        return (primary, secondary, extras)
    }
}

struct ClaudeUsageResponse: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var utilization: Double
        var resetsAt: Date?
    }

    /// Window key → window, for every response key that looks like one.
    var windows: [String: Window]

    /// Keys that carry a `utilization` field but are not rate-limit windows.
    private static let excludedKeys: Set<String> = ["extra_usage"]

    static func parse(_ data: Data) throws -> ClaudeUsageResponse {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFetchError.parsing(description: "oauth/usage: not JSON")
        }
        guard let root = object as? [String: Any] else {
            throw ProviderFetchError.parsing(description: "oauth/usage: unexpected top-level shape")
        }

        var windows: [String: Window] = [:]
        for (key, value) in root where !excludedKeys.contains(key) {
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO)
            windows[key] = Window(utilization: utilization, resetsAt: resetsAt)
        }
        // A 2xx whose body carries no window-shaped keys (e.g. an error
        // envelope) is a schema problem, not "all limits are gone".
        guard !windows.isEmpty else {
            throw ProviderFetchError.parsing(description: "oauth/usage: no rate-limit windows in response")
        }
        return ClaudeUsageResponse(windows: windows)
    }

    /// One-off convenience over `ClaudeISO8601`; for per-line parsing reuse a
    /// single `ClaudeISO8601` instance instead.
    static func parseISO(_ string: String) -> Date? {
        ClaudeISO8601().date(from: string)
    }
}

/// ISO-8601 parsing tolerant of the timestamp shapes both Claude sources emit:
/// JSONL logs use millisecond "…T21:47:03.483Z", the usage endpoint emits
/// 6-digit fractional seconds "…T02:40:00.086425+00:00", and `resets_at` can
/// also arrive without any fraction.
///
/// Holds its two `ISO8601DateFormatter`s so hot loops (one call per log line)
/// don't re-allocate them. Not Sendable — create one per parse pass.
struct ClaudeISO8601 {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        if let date = fractional.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        // Unusual fractional precision: normalize to milliseconds and retry.
        guard let dotIndex = string.firstIndex(of: ".") else { return nil }
        let tail = string[string.index(after: dotIndex)...]
        guard let suffixIndex = tail.firstIndex(where: { !$0.isNumber }), suffixIndex > tail.startIndex else {
            return nil
        }
        let millis = String(tail[..<suffixIndex].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let suffix = tail[suffixIndex...]
        if let date = fractional.date(from: "\(string[..<dotIndex]).\(millis)\(suffix)") { return date }
        return plain.date(from: "\(string[..<dotIndex])\(suffix)")
    }
}
