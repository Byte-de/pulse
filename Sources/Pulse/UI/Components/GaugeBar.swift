import SwiftUI

/// 5pt capsule gauge for a limit window, in either reading direction.
///
/// `direction` decides what the bar means, and the caller must render the
/// headline percentage with the same setting (`GaugeDirection.displayValue`):
///
/// - `.used` - conventional progress bar. Fill grows left to right with
///   consumption, percentage counts 0 -> 100.
/// - `.remaining` - fuel gauge. Fill drains right to left, percentage counts
///   100 -> 0. A full bar means full credits.
///
/// The optional pace tick marks where the *window clock* sits, and always
/// tracks the fill's direction, so the two are directly comparable:
/// fill ahead of the tick means credits are outlasting the clock, fill behind
/// it means they are draining faster than the window refills.
///
/// Colour keys off raw `utilization` in both directions: red always means
/// nearly exhausted, which is a long bar under `.used` and a short one under
/// `.remaining`.
struct GaugeBar: View {
    /// 0...100 utilization (how much is *used*), regardless of direction.
    let utilization: Double
    var color: Color? = nil
    /// Elapsed fraction of the window, 0...1. Nil for windows with no clock
    /// (no reset time, or a spend budget that does not refill on a timer).
    var paceMarker: Double? = nil
    var direction: SettingsStore.GaugeDirection = .remaining

    var body: some View {
        GeometryReader { proxy in
            let fraction = direction.fillFraction(utilization: utilization)
            // Keep a sliver visible while the bar is non-empty, so "almost
            // gone" never renders identically to "gone".
            let minVisible: CGFloat = fraction > 0 ? Layout.progressBarHeight : 0
            let width = max(proxy.size.width * fraction, minVisible)

            ZStack(alignment: .leading) {
                Capsule().fill(PulseColor.trackFill)
                Capsule()
                    .fill(color ?? PulseColor.threshold(utilization: utilization))
                    .frame(width: width)
                    .animation(Motion.gaugeFill, value: utilization)
                    .animation(Motion.staleTint, value: utilization >= 50)

                if let paceMarker {
                    let position = direction.markerPosition(elapsedFraction: paceMarker)
                    // Inset so the tick stays inside the capsule at both ends.
                    let usable = max(proxy.size.width - Layout.paceMarkerWidth, 0)
                    Capsule()
                        .fill(PulseColor.paceMarker)
                        .frame(
                            width: Layout.paceMarkerWidth,
                            height: Layout.progressBarHeight + Layout.paceMarkerOverhang
                        )
                        .offset(x: usable * position)
                        .animation(Motion.gaugeFill, value: position)
                        .accessibilityLabel(
                            direction == .used ? "On-pace position" : "Time remaining in window"
                        )
                }
            }
        }
        .frame(height: Layout.progressBarHeight + Layout.paceMarkerOverhang)
    }
}
