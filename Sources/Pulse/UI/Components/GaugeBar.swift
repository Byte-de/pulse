import SwiftUI

/// 5pt capsule progress bar, threshold-colored, zero-bounce fill animation.
/// Shows a minimum visible fill so a non-zero value is never a 0-width sliver.
struct GaugeBar: View {
    /// 0...100 (clamped for the fill, raw value shown elsewhere).
    let utilization: Double
    var color: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(utilization / 100, 0), 1)
            let minVisible: CGFloat = utilization > 0 ? Layout.progressBarHeight : 0
            let width = max(proxy.size.width * fraction, minVisible)

            ZStack(alignment: .leading) {
                Capsule().fill(PulseColor.trackFill)
                Capsule()
                    .fill(color ?? PulseColor.threshold(utilization: utilization))
                    .frame(width: width)
                    .animation(Motion.gaugeFill, value: utilization)
                    .animation(Motion.staleTint, value: utilization >= 50)
            }
        }
        .frame(height: Layout.progressBarHeight)
    }
}
