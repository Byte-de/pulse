import SwiftUI

/// Minimal filled line for a bounded 0...100 series (CPU history).
///
/// Not a Swift Charts view on purpose: this redraws every two seconds behind a
/// popover, and a Chart with axes, scales and marks is far more machinery than
/// a 60-point polyline needs.
struct Sparkline: View {
    let values: [Double]
    var color: Color = PulseColor.ok
    /// Top of the vertical scale. Fixed rather than data-derived so a quiet
    /// minute does not silently rescale into looking like a busy one.
    var maximum: Double = 100

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if values.count >= 2 {
                let points = Self.points(values, in: size, maximum: maximum)
                ZStack {
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.addLine(to: CGPoint(x: points[0].x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                .animation(Motion.numberTick, value: values)
            } else {
                // A single sample has no shape to draw; the baseline keeps the
                // card's height stable instead of popping when data arrives.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                }
                .stroke(PulseColor.trackFill, lineWidth: 1)
            }
        }
    }

    /// Newest sample pinned to the right edge, so a partly-filled history grows
    /// leftward instead of stretching a few points across the whole card.
    static func points(_ values: [Double], in size: CGSize, maximum: Double) -> [CGPoint] {
        guard values.count >= 2, maximum > 0 else { return [] }
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            let clamped = min(max(value, 0), maximum)
            let y = size.height - CGFloat(clamped / maximum) * size.height
            return CGPoint(x: CGFloat(index) * step, y: y)
        }
    }
}
