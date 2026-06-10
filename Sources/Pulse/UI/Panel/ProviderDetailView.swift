import SwiftUI

/// The card stack for one provider tab, rendered from whatever the snapshot
/// carries. Stale data stays visible, desaturated, with the footer flagging it.
struct ProviderDetailView: View {
    let descriptor: ProviderDescriptor
    let record: ProviderRecord
    let settings: SettingsStore
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        switch record.displayState {
        case .loading:
            ProviderLoadingView(descriptor: descriptor)
        case .notConnected(let hint):
            NotConnectedView(descriptor: descriptor, hint: hint, openSettings: openSettings)
        case .error(let error):
            ProviderErrorView(descriptor: descriptor, error: error, retry: retry)
        case .data:
            if let snapshot = record.snapshot {
                cards(for: snapshot)
            }
        }
    }

    private func cards(for snapshot: UsageSnapshot) -> some View {
        VStack(spacing: Layout.cardGap) {
            if let primary = snapshot.primary {
                LimitGaugeCard(window: primary, trend: record.primaryTrend, isStale: record.isStale)
            }
            if let secondary = snapshot.secondary {
                LimitGaugeCard(window: secondary, trend: record.secondaryTrend, isStale: record.isStale)
            }
            if !snapshot.extraWindows.isEmpty {
                ExtraLimitsCard(
                    title: descriptor.id == .gemini ? "Model Quotas" : "Model Limits",
                    windows: snapshot.extraWindows
                )
            }
            if snapshot.primary != nil {
                UsageRateCard(series: record.rateSeries)
            }
            if snapshot.dailyUsage.contains(where: { $0.totals.total > 0 }) {
                DailyUsageCard(
                    histograms: snapshot.histograms.isEmpty
                        ? [.week: snapshot.dailyUsage]
                        : snapshot.histograms,
                    settings: settings
                )
            }
            if let tokens = snapshot.tokens {
                TokenUsageCard(report: tokens, accent: PulseColor.accent(descriptor.id))
            }
            if !snapshot.statusNotes.isEmpty {
                statusNotes(snapshot.statusNotes)
            }
        }
    }

    private func statusNotes(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes, id: \.self) { note in
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                    Text(note)
                        .font(Typo.footer)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
