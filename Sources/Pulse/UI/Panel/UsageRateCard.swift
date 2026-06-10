import SwiftUI

/// "Usage Rate" card: rate-of-change line chart over the trailing 5h window.
struct UsageRateCard: View {
    let series: [RatePoint]

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "chart.xyaxis.line", title: "Usage Rate") {
                    Text("5h window")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if series.count >= 2 {
                    UsageRateChart(points: series)
                } else {
                    Text("Collecting samples — the rate trend appears after a few refreshes.")
                        .font(Typo.footer)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}
