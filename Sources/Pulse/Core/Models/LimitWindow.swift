import Foundation

/// One rate-limit gauge: a utilization percentage inside a (usually rolling) window.
///
/// Examples: Claude's 5-hour session and 7-day window, Codex's 5h/weekly limits,
/// Cursor's monthly plan usage and on-demand spend, Gemini's per-model daily quota.
struct LimitWindow: Sendable, Equatable, Identifiable {
    /// Stable identity within a provider, e.g. "five_hour", "seven_day", "quota.gemini-2.5-pro".
    let id: String
    /// Card title, e.g. "5-Hour Session".
    var title: String
    /// SF Symbol shown next to the title.
    var systemImage: String
    /// 0...100 (may exceed 100 when a provider overshoots).
    var utilization: Double
    /// When the window resets, if the provider reports it.
    var resetsAt: Date?
    /// Length of the window (5h, 7d, ...). Used to derive elapsed fraction for pace.
    var windowDuration: TimeInterval?
    /// Explicit period start (e.g. Cursor billing cycle). Preferred over derivation.
    var periodStart: Date?
    /// Optional secondary line, e.g. "$3.20 of $125" for spend windows.
    var detail: String?

    init(
        id: String,
        title: String,
        systemImage: String,
        utilization: Double,
        resetsAt: Date? = nil,
        windowDuration: TimeInterval? = nil,
        periodStart: Date? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.periodStart = periodStart
        self.detail = detail
    }

    /// Fraction of the window that has elapsed (0...1), if derivable.
    ///
    /// Prefers an explicit `periodStart`; otherwise derives the start from
    /// `resetsAt - windowDuration` (correct for rolling windows like 5h/7d).
    func elapsedFraction(now: Date = .now) -> Double? {
        if let periodStart, let resetsAt, resetsAt > periodStart {
            return min(1, max(0, now.timeIntervalSince(periodStart) / resetsAt.timeIntervalSince(periodStart)))
        }
        if let resetsAt, let windowDuration, windowDuration > 0 {
            let remaining = max(0, resetsAt.timeIntervalSince(now))
            return min(1, max(0, 1 - remaining / windowDuration))
        }
        return nil
    }
}
