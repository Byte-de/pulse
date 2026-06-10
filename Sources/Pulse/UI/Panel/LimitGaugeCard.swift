import SwiftUI

/// "5-Hour Session" / "Weekly Limit" style card: title + live % + trend in the
/// header, threshold-colored gauge, reset countdown and pace caption.
struct LimitGaugeCard: View {
    let window: LimitWindow
    let trend: Trend?
    var isStale = false

    /// Ticks the countdown caption while visible.
    private let clock = Date.now

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: window.systemImage, title: window.title) {
                    HStack(spacing: 5) {
                        Text(Formatters.percent(window.utilization))
                            .font(Typo.gaugeValue)
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: window.utilization))
                            .animation(Motion.numberTick, value: window.utilization)
                        if let trend {
                            TrendBadge(trend: trend)
                        }
                    }
                }

                GaugeBar(utilization: window.utilization)

                captionRow
            }
            .opacity(isStale ? 0.6 : 1)
            .animation(Motion.staleTint, value: isStale)
        }
    }

    @ViewBuilder
    private var captionRow: some View {
        HStack(alignment: .firstTextBaseline) {
            if let detail = window.detail {
                Text(detail)
                    .font(Typo.captionValue)
                    .foregroundStyle(.secondary)
            } else if let resetsAt = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    resetCaption(resetsAt: resetsAt, now: context.date)
                }
            } else {
                Text("Resets: —")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let pace = Pace.evaluate(
                utilization: window.utilization,
                elapsedFraction: window.elapsedFraction()
            ) {
                PaceLabel(pace: pace)
            }
        }
    }

    private func resetCaption(resetsAt: Date, now: Date) -> some View {
        let countdown = Text(Formatters.countdown(to: resetsAt, now: now))
            .foregroundStyle(.primary)
            .fontWeight(.semibold)
        let withinDay = resetsAt.timeIntervalSince(now) < 24 * 3600
        let caption: Text = withinDay
            ? Text("Resets in: \(countdown) at \(Formatters.clockTime(resetsAt))")
            : Text("Resets in: \(countdown)")
        return caption
            .font(Typo.captionValue)
            .foregroundStyle(.secondary)
    }
}

/// Compact gauge rows for additional windows (per-model weekly caps, Gemini
/// per-model quotas): name · thin bar · %.
struct ExtraLimitsCard: View {
    let title: String
    let windows: [LimitWindow]

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "slider.horizontal.3", title: title) { EmptyView() }
                VStack(spacing: 6) {
                    ForEach(windows) { window in
                        HStack(spacing: 8) {
                            Text(window.title)
                                .font(Typo.tableLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 110, alignment: .leading)
                            GaugeBar(utilization: window.utilization)
                            Text(Formatters.percent(window.utilization))
                                .font(Typo.captionValue)
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                                .contentTransition(.numericText(value: window.utilization))
                        }
                        .help(resetHelp(window))
                    }
                }
            }
        }
    }

    private func resetHelp(_ window: LimitWindow) -> String {
        guard let resetsAt = window.resetsAt else { return window.title }
        return "\(window.title) — resets in \(Formatters.countdown(to: resetsAt))"
    }
}
