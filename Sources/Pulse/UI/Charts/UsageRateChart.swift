import Charts
import SwiftUI

/// Usage-rate line: Δ utilization per 15-min bucket over the last 5h.
/// Above zero = consuming (red), below = window rolling off (green); the series
/// is split at zero crossings so each side carries its own color and soft fill.
struct UsageRateChart: View {
    let points: [RatePoint]

    private struct Segment: Identifiable {
        let id: Int
        let isAbove: Bool
        let points: [RatePoint]
    }

    var body: some View {
        let segments = Self.signSegments(points)
        let limit = Self.axisLimit(points)

        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.primary.opacity(0.15))
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(segments) { segment in
                let color = segment.isAbove ? PulseColor.critical : PulseColor.ok
                ForEach(segment.points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Rate", point.delta),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.16), color.opacity(0.03)],
                            startPoint: segment.isAbove ? .top : .bottom,
                            endPoint: segment.isAbove ? .bottom : .top
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Rate", point.delta),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(color)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: -limit...limit)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-limit, limit]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v > 0 ? "+\(Int(v))%" : "\(Int(v))%")
                            .font(Typo.axisLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 56)
        .animation(Motion.numberTick, value: points)
    }

    /// Splits points into same-sign runs, inserting interpolated zero points at
    /// crossings so adjacent segments meet exactly on the axis.
    private static func signSegments(_ points: [RatePoint]) -> [Segment] {
        guard !points.isEmpty else { return [] }
        var segments: [Segment] = []
        var current: [RatePoint] = []
        // Strictly-positive = consuming (red); zero/flat runs read as calm green.
        var currentAbove = points[0].delta > 0

        func flush() {
            if current.count > 1 || (current.count == 1 && segments.isEmpty) {
                segments.append(Segment(id: segments.count, isAbove: currentAbove, points: current))
            }
            current = []
        }

        for point in points {
            let above = point.delta > 0
            if above != currentAbove, let last = current.last {
                let crossing = Self.zeroCrossing(last, point)
                current.append(crossing)
                flush()
                currentAbove = above
                current = [crossing]
            }
            current.append(point)
        }
        flush()
        return segments
    }

    private static func zeroCrossing(_ a: RatePoint, _ b: RatePoint) -> RatePoint {
        let span = b.delta - a.delta
        guard span != 0 else { return RatePoint(date: a.date, delta: 0) }
        let fraction = -a.delta / span
        let interval = b.date.timeIntervalSince(a.date) * fraction
        return RatePoint(date: a.date.addingTimeInterval(interval), delta: 0)
    }

    /// Symmetric axis limit: 30 by default (the reference look), expanding in
    /// 10-point steps when the data exceeds it.
    private static func axisLimit(_ points: [RatePoint]) -> Double {
        let peak = points.map { abs($0.delta) }.max() ?? 0
        return max(30, (peak / 10).rounded(.up) * 10)
    }
}
