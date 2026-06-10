import Foundation

/// Whether the user is on track to stay inside a limit window.
///
/// Compares actual utilization against the "expected" utilization for the elapsed
/// fraction of the window (pace ratio = used / expected), with absolute floors so
/// a nearly-full window is never reported as safe.
enum Pace: String, Sendable, Equatable, CaseIterable {
    case safe
    case elevated
    case critical

    /// Thresholds from docs/DESIGN.md: ratio ≤ 1.0 safe, ≤ 1.5 elevated, else critical.
    /// Floors: utilization ≥ 95 is always critical, ≥ 85 at least elevated.
    /// Early in a window (< 5% elapsed) the ratio is unstable, so only absolute
    /// utilization is considered.
    static func evaluate(utilization: Double, elapsedFraction: Double?) -> Pace? {
        if utilization >= 95 { return .critical }

        guard let elapsed = elapsedFraction, elapsed > 0 else {
            return utilization >= 85 ? .elevated : nil
        }

        let floor: Pace = utilization >= 85 ? .elevated : .safe
        guard elapsed >= 0.05 else {
            if utilization >= 85 { return .elevated }
            return utilization >= 50 ? .elevated : .safe
        }

        let expected = elapsed * 100
        let ratio = utilization / expected
        let fromRatio: Pace = ratio <= 1.0 ? .safe : (ratio <= 1.5 ? .elevated : .critical)
        return max(fromRatio, floor)
    }

    var label: String { rawValue }
}

extension Pace: Comparable {
    private var rank: Int {
        switch self {
        case .safe: 0
        case .elevated: 1
        case .critical: 2
        }
    }

    static func < (lhs: Pace, rhs: Pace) -> Bool { lhs.rank < rhs.rank }
}

/// Change of a utilization value against a reference sample (~1h ago).
/// In Pulse, usage going *up* is the negative signal (rendered red),
/// going down is recovery (rendered green).
struct Trend: Sendable, Equatable {
    /// Percentage-point delta vs the reference sample.
    var delta: Double

    enum Direction: Sendable { case up, down, flat }

    var direction: Direction {
        if delta > 0.05 { return .up }
        if delta < -0.05 { return .down }
        return .flat
    }
}
