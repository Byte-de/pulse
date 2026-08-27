import SwiftUI

/// "5-Hour Session" / "Weekly Limit" style card: title + live % + trend in the
/// header, threshold-colored gauge, reset countdown and pace caption.
struct LimitGaugeCard: View {
    let window: LimitWindow
    let trend: Trend?
    var isStale = false
    /// Used vs remaining. Drives the bar, the headline number and the pace
    /// tick together, so the card can never show a bar and a percentage that
    /// disagree about which way is "more left".
    var direction: SettingsStore.GaugeDirection = .remaining

    /// Ticks the countdown caption while visible.
    private let clock = Date.now

    private var displayValue: Double {
        direction.displayValue(utilization: window.utilization)
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: window.systemImage, title: window.title) {
                    HStack(spacing: 5) {
                        Text(Formatters.percent(displayValue))
                            .font(Typo.gaugeValue)
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: displayValue))
                            .animation(Motion.numberTick, value: displayValue)
                        if let trend {
                            TrendBadge(trend: trend)
                        }
                    }
                }

                GaugeBar(
                    utilization: window.utilization,
                    paceMarker: window.elapsedFraction(),
                    direction: direction
                )
                .help(paceHelp)

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

    /// Says out loud what the bar and tick mean, since neither is
    /// self-explanatory the first time it is seen. Phrased in the direction the
    /// user picked, so the tooltip never contradicts the number above it.
    private var paceHelp: String {
        let used = window.utilization
        let left = max(0, 100 - used)
        guard let elapsed = window.elapsedFraction() else {
            return direction == .used
                ? "\(window.title) - \(Formatters.percent(used)) used"
                : "\(window.title) - \(Formatters.percent(left)) of credits left"
        }
        let timeUsed = min(100, max(0, elapsed * 100))
        let timeLeft = 100 - timeUsed
        let aheadOfClock = used > timeUsed
        let gap = Formatters.percent(abs(used - timeUsed))
        let verdict = aheadOfClock
            ? "Credits are draining \(gap) faster than the clock"
            : "Credits are outlasting the clock by \(gap)"

        switch direction {
        case .used:
            return "Bar = \(Formatters.percent(used)) used. "
                + "Tick = \(Formatters.percent(timeUsed)) of the window elapsed. \(verdict)."
        case .remaining:
            return "Bar = \(Formatters.percent(left)) of credits left. "
                + "Tick = \(Formatters.percent(timeLeft)) of the window left. \(verdict)."
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
    var direction: SettingsStore.GaugeDirection = .remaining

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
                            GaugeBar(
                                utilization: window.utilization,
                                paceMarker: window.elapsedFraction(),
                                direction: direction
                            )
                            Text(Formatters.percent(direction.displayValue(utilization: window.utilization)))
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
        var parts: [String] = [window.title]
        if let resetsAt = window.resetsAt {
            parts.append("resets in \(Formatters.countdown(to: resetsAt))")
        }
        if let elapsed = window.elapsedFraction() {
            let timeUsed = min(100, max(0, elapsed * 100))
            parts.append(
                direction == .used
                    ? "tick at \(Formatters.percent(timeUsed)) of the window elapsed"
                    : "tick at \(Formatters.percent(100 - timeUsed)) of the window left"
            )
        }
        return parts.joined(separator: " - ")
    }
}
