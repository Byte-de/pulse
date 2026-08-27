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
    /// Whether to draw the on-pace tick. A window with no clock never gets one
    /// regardless, so this only suppresses the ticks that could be drawn.
    var showPaceMarker = true

    /// Ticks the countdown caption while visible.
    private let clock = Date.now

    /// The elapsed fraction to hand the gauge: nil when the user turned the
    /// marker off, or when the window has no clock to derive it from.
    private var markerFraction: Double? {
        showPaceMarker ? window.elapsedFraction() : nil
    }

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
                    paceMarker: markerFraction,
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
    /// user picked, and drops the tick sentence entirely when no tick is drawn,
    /// so the tooltip never describes something that is not on screen.
    private var paceHelp: String {
        let used = window.utilization
        let left = max(0, 100 - used)
        let barText = direction == .used
            ? "Bar = \(Formatters.percent(used)) used."
            : "Bar = \(Formatters.percent(left)) of credits left."

        guard let elapsed = markerFraction else {
            return "\(window.title) - \(barText.dropFirst("Bar = ".count))"
        }
        let timeUsed = min(100, max(0, elapsed * 100))
        let timeLeft = 100 - timeUsed
        let aheadOfClock = used > timeUsed
        let gap = Formatters.percent(abs(used - timeUsed))
        let verdict = aheadOfClock
            ? "Credits are draining \(gap) faster than the clock"
            : "Credits are outlasting the clock by \(gap)"
        let tickText = direction == .used
            ? "Tick = \(Formatters.percent(timeUsed)) of the window elapsed."
            : "Tick = \(Formatters.percent(timeLeft)) of the window left."
        return "\(barText) \(tickText) \(verdict)."
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
    var showPaceMarker = true

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
                                paceMarker: showPaceMarker ? window.elapsedFraction() : nil,
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
        if showPaceMarker, let elapsed = window.elapsedFraction() {
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
