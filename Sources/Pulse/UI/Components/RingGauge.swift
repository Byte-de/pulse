import SwiftUI

/// Circular sibling of `GaugeBar`: one limit window drawn as a ring with the
/// percentage in the middle.
///
/// Exists for the simple panel view, where a provider gets one number and that
/// number has to be readable from across the desk. A bar of the same
/// information is 5pt tall and disappears; a 104pt ring does not.
///
/// Everything about how it reads is shared with `GaugeBar` on purpose:
///
/// - `direction` decides meaning, and the caller must render the centre
///   percentage with the same setting (`GaugeDirection.displayValue`), or the
///   ring and the number would disagree about which way is "more left".
/// - Colour keys off raw `utilization`, so red always means nearly exhausted -
///   a long arc under `.used`, a short one under `.remaining`.
/// - The pace tick marks where the *window clock* sits and tracks the arc's
///   direction, so arc ahead of tick = credits outlasting the clock.
///
/// The arc always starts at 12 o'clock and grows clockwise, which is the one
/// convention every other dial on the machine uses.
struct RingGauge: View {
    /// 0...100 utilization (how much is *used*), regardless of direction.
    let utilization: Double
    /// Elapsed fraction of the window, 0...1, or nil to draw no tick - either
    /// because the window has no clock or because the user turned the marker
    /// off.
    var paceMarker: Double? = nil
    var direction: SettingsStore.GaugeDirection = .remaining
    var diameter: CGFloat = 104
    var lineWidth: CGFloat = 9
    /// Small line under the percentage: "left", "used", a countdown.
    var caption: String?

    private var fraction: Double {
        direction.fillFraction(utilization: utilization)
    }

    private var color: Color {
        PulseColor.threshold(utilization: utilization)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(PulseColor.trackFill, lineWidth: lineWidth)

            Circle()
                // Keep a visible cap while the window is non-empty, so
                // "almost gone" never renders identically to "gone" - the same
                // rule GaugeBar applies to its minimum width.
                .trim(from: 0, to: max(fraction, fraction > 0 ? 0.008 : 0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.gaugeFill, value: utilization)
                .animation(Motion.staleTint, value: utilization >= 50)

            if let paceMarker {
                let position = direction.markerPosition(elapsedFraction: paceMarker)
                Capsule()
                    .fill(PulseColor.paceMarker)
                    .frame(
                        width: Layout.paceMarkerWidth,
                        height: lineWidth + 2 * Layout.paceMarkerOverhang
                    )
                    .offset(y: -(diameter - lineWidth) / 2)
                    .rotationEffect(.degrees(360 * position))
                    .animation(Motion.gaugeFill, value: position)
                    .accessibilityLabel(
                        direction == .used ? "On-pace position" : "Time remaining in window"
                    )
            }

            VStack(spacing: 0) {
                Text(Formatters.percent(direction.displayValue(utilization: utilization)))
                    .font(.system(size: diameter * 0.17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    // NO `.animation(_:value:)`: same rule as everywhere else
                    // in this app - `contentTransition` animates the digits
                    // from the value actually changing, an attached animation
                    // would keep a transaction open and redraw at display rate.
                    .contentTransition(.numericText(value: utilization))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
