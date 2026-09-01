import SwiftUI

/// One provider, reduced to the two things that decide whether to start
/// another run: how much of the live session window is left (ring), and how
/// much of the week is left (bar underneath it).
///
/// The session ring is on top and the weekly bar below because the session is
/// what runs out during the next hour; the week is context for it. That order
/// is a decision, not an accident - the first draft had the weekly bar above
/// the ring and it made the slower number the headline.
///
/// Everything else the provider publishes - rates, histograms, tokens,
/// per-model caps - lives in the full view, one button away.
struct ProviderGlanceCard: View {
    let descriptor: ProviderDescriptor
    let record: ProviderRecord
    let settings: SettingsStore
    let openSettings: () -> Void

    private var direction: SettingsStore.GaugeDirection { settings.gaugeDirection }

    var body: some View {
        CardView {
            switch record.displayState {
            case .loading:
                placeholder(symbol: "clock", text: "Reading \(descriptor.name)…")
            case .notConnected:
                Button(action: openSettings) {
                    placeholder(symbol: "key.slash", text: "Not connected")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("\(descriptor.name) isn't connected. Open Settings.")
            case .error(let error):
                placeholder(symbol: "exclamationmark.triangle", text: error.userMessage)
            case .data:
                if let snapshot = record.snapshot {
                    content(for: snapshot)
                } else {
                    placeholder(symbol: "clock", text: "No data")
                }
            }
        }
    }

    /// The ring takes the session window when there is one and falls back to
    /// the weekly window when there is not.
    ///
    /// Not every provider has a 5-hour window: Cursor's primary is a monthly
    /// plan, Gemini's is a daily quota, and a Claude account that has been idle
    /// long enough for its session to expire publishes a weekly window and no
    /// session at all. Without the fallback that account rendered a 164pt
    /// column saying "No session window" while its weekly figure - the one
    /// piece of information it had - was suppressed as the bar below it.
    private func windows(for snapshot: UsageSnapshot) -> (ring: LimitWindow?, bar: LimitWindow?) {
        if let primary = snapshot.primary { return (primary, snapshot.secondary) }
        return (snapshot.secondary, nil)
    }

    @ViewBuilder
    private func content(for snapshot: UsageSnapshot) -> some View {
        let pair = windows(for: snapshot)
        VStack(spacing: 10) {
            if let ringWindow = pair.ring {
                ring(for: ringWindow)
            } else {
                // Say WHY, not just that there is nothing. A provider with no
                // windows always knows the reason - an expired token, a 429, a
                // network blip - and it publishes it in `statusNotes`. The
                // first version of this card dropped those notes, so an
                // account whose limits endpoint had failed rendered as a blank
                // "No limits reported" that was indistinguishable from an
                // account that simply has no limits, and looked like the panel
                // had lost data it used to show.
                placeholder(
                    symbol: "exclamationmark.triangle",
                    text: snapshot.statusNotes.first ?? "No limits reported"
                )
            }

            if let barWindow = pair.bar {
                Divider().overlay(PulseColor.hairline.opacity(0.6))
                weekly(barWindow)
            }
        }
        .opacity(record.isStale ? 0.6 : 1)
        .animation(Motion.staleTint, value: record.isStale)
        .frame(maxWidth: .infinity)
    }

    private func ring(for window: LimitWindow) -> some View {
        VStack(spacing: 6) {
            RingGauge(
                utilization: window.utilization,
                paceMarker: settings.showPaceMarker ? window.elapsedFraction() : nil,
                direction: direction,
                caption: direction == .used ? "used" : "left"
            )

            Text(window.title)
                .font(Typo.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)

            resetLine(for: window)
        }
        .frame(maxWidth: .infinity)
        .help(help(for: window))
    }

    private func weekly(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(window.title)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Formatters.percent(direction.displayValue(utilization: window.utilization)))
                    .font(Typo.captionValue)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: window.utilization))
                    .fixedSize()
            }

            GaugeBar(
                utilization: window.utilization,
                paceMarker: settings.showPaceMarker ? window.elapsedFraction() : nil,
                direction: direction
            )
        }
        .frame(maxWidth: .infinity)
        .help(help(for: window))
    }

    /// Reset countdown. `TimelineView` at 60s, never faster: nothing here
    /// changes within a minute and a 1-second tick is what once cost this app
    /// 34% of a core (see PanelFooter).
    @ViewBuilder
    private func resetLine(for window: LimitWindow) -> some View {
        if let resetsAt = window.resetsAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("resets in \(Formatters.countdown(to: resetsAt, now: context.date))")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let detail = window.detail {
            Text(detail)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func help(for window: LimitWindow) -> String {
        let used = window.utilization
        var parts = [window.title]
        // Phrased in the direction the user picked, so the tooltip can never
        // contradict the ring it describes.
        parts.append("\(Formatters.percent(direction.displayValue(utilization: used))) "
            + (direction == .used ? "used" : "left"))
        if let resetsAt = window.resetsAt {
            parts.append("resets in \(Formatters.countdown(to: resetsAt))")
        }
        if settings.showPaceMarker, let elapsed = window.elapsedFraction() {
            // A gap between two percentages, not a percentage of the window:
            // it reads the same in either direction, so it is deliberately not
            // routed through `displayValue`.
            let timeUsed = min(100, max(0, elapsed * 100))
            parts.append(used > timeUsed
                ? "draining \(Formatters.percent(used - timeUsed)) faster than the clock"
                : "outlasting the clock by \(Formatters.percent(timeUsed - used))")
        }
        return parts.joined(separator: " · ")
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            ThemedIcon(symbol: symbol, pointSize: 18, weight: .light)
                .foregroundStyle(PulseColor.accent(descriptor.id).opacity(0.7))
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                // Without this the column's fixed width is not treated as the
                // wrapping width and a real message ("Limits unavailable: Rate
                // limited by the provider — retrying later") renders as one
                // truncated line, which hides the very reason the card exists
                // to show.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}
