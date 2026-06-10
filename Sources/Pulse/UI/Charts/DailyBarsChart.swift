import Charts
import SwiftUI

/// Usage histogram bars for any timeframe: 24 hours, 7/30 days, or 12 months.
/// Bars are colored by intensity relative to the busiest bucket (green →
/// yellow), the current bucket at full opacity. The hovered bucket is reported
/// upward (the card shows it in its header) instead of annotating inside the
/// plot — annotations change the plot height and visibly squash every bar.
struct DailyBarsChart: View {
    let buckets: [DailyUsage]
    let timeframe: UsageTimeframe
    var onHover: (DailyUsage?) -> Void = { _ in }

    @State private var hasAppeared = false

    private var maxTotal: Int64 { max(buckets.map(\.totals.total).max() ?? 0, 1) }
    private var calendar: Calendar { .current }

    private var barWidth: MarkDimension {
        switch timeframe {
        case .day: .fixed(8)
        case .week: .fixed(24)
        case .month: .fixed(6)
        case .year: .fixed(16)
        }
    }

    /// Stagger compresses for dense charts so the full draw-in stays < 300ms.
    private var staggerStep: Double { buckets.count > 12 ? 0.008 : 0.03 }

    var body: some View {
        Chart(buckets) { bucket in
            let relative = Double(bucket.totals.total) / Double(maxTotal)
            let isCurrent = calendar.isDate(bucket.date, equalTo: .now, toGranularity: timeframe.bucket)

            BarMark(
                x: .value("Bucket", bucket.date, unit: timeframe.bucket),
                y: .value("Tokens", hasAppeared ? bucket.totals.total : 0),
                width: barWidth
            )
            .cornerRadius(timeframe == .month ? 2 : 3)
            .foregroundStyle(
                (relative >= 0.5 ? PulseColor.warn : PulseColor.ok)
                    .opacity(isCurrent ? 1 : 0.85)
            )
            .opacity(hasAppeared ? 1 : 0)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(Self.axisLabel(for: date, timeframe: timeframe))
                            .font(Typo.axisLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geometry[plotFrame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                onHover(bucket(containing: date))
                            }
                        case .ended:
                            onHover(nil)
                        }
                    }
            }
        }
        .frame(height: 64)
        .animation(Motion.numberTick, value: buckets)
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(Motion.chartDrawIn) { hasAppeared = true }
        }
        .onDisappear { onHover(nil) }
    }

    private func bucket(containing date: Date) -> DailyUsage? {
        buckets.first { calendar.isDate($0.date, equalTo: date, toGranularity: timeframe.bucket) }
    }

    /// Subset of bucket dates that get an axis label, per density.
    private var axisDates: [Date] {
        switch timeframe {
        case .week, .year:
            return buckets.map(\.date)
        case .day:
            return buckets.filter { calendar.component(.hour, from: $0.date) % 6 == 0 }.map(\.date)
        case .month:
            return buckets.filter { calendar.component(.day, from: $0.date) % 5 == 0 }.map(\.date)
        }
    }

    static func axisLabel(for date: Date, timeframe: UsageTimeframe) -> String {
        switch timeframe {
        case .day:
            String(Calendar.current.component(.hour, from: date))
        case .week:
            Formatters.weekday(date)
        case .month:
            String(Calendar.current.component(.day, from: date))
        case .year:
            date.formatted(.dateTime.month(.narrow))
        }
    }

    /// Hover label shown in the card header, e.g. "Tue · 184.3k", "14:00 · 52k".
    static func hoverLabel(for bucket: DailyUsage, timeframe: UsageTimeframe) -> String {
        let when: String = switch timeframe {
        case .day:
            Formatters.clockTime(bucket.date)
        case .week:
            Formatters.weekday(bucket.date)
        case .month:
            bucket.date.formatted(.dateTime.day().month(.abbreviated))
        case .year:
            bucket.date.formatted(.dateTime.month(.abbreviated))
        }
        return "\(when) · \(Formatters.tokenCount(bucket.totals.total))"
    }
}
