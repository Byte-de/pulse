import SwiftUI

/// Usage histogram card. The trailing badge shows the active timeframe and
/// cycles through the frames the provider supports (1d → 7d → 30d → 1y);
/// hovering a bar swaps the badge for that bucket's value, so the plot itself
/// never changes height.
struct DailyUsageCard: View {
    /// Timeframe → buckets; only supported frames are present.
    let histograms: [UsageTimeframe: [DailyUsage]]
    @Bindable var settings: SettingsStore

    @State private var hovered: DailyUsage?

    private var available: [UsageTimeframe] {
        UsageTimeframe.allCases.filter { histograms[$0] != nil }
    }

    /// The persisted preference, clamped to what this provider supports.
    private var timeframe: UsageTimeframe {
        if available.contains(settings.dailyTimeframe) { return settings.dailyTimeframe }
        return available.contains(.week) ? .week : (available.first ?? .week)
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "chart.bar.fill", title: title) {
                    accessory
                }
                DailyBarsChart(
                    buckets: histograms[timeframe] ?? [],
                    timeframe: timeframe,
                    onHover: { bucket in
                        withAnimation(Motion.hover) { hovered = bucket }
                    }
                )
                .id(timeframe) // fresh draw-in per timeframe switch
            }
        }
    }

    private var title: String {
        timeframe == .day ? "Hourly Usage" : "Daily Usage"
    }

    @ViewBuilder
    private var accessory: some View {
        if let hovered, hovered.totals.total > 0 {
            Text(DailyBarsChart.hoverLabel(for: hovered, timeframe: timeframe))
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .transition(.blurReplace)
        } else if available.count > 1 {
            Button(action: cycleTimeframe) {
                InfoTag(text: timeframe.label)
                    .contentTransition(.numericText())
            }
            .buttonStyle(PressableButtonStyle())
            .focusEffectDisabled()
            .help("Switch timeframe")
        } else {
            InfoTag(text: timeframe.label)
        }
    }

    private func cycleTimeframe() {
        guard let index = available.firstIndex(of: timeframe) else { return }
        let next = available[(index + 1) % available.count]
        withAnimation(Motion.iconSwap) {
            settings.dailyTimeframe = next
        }
    }
}
