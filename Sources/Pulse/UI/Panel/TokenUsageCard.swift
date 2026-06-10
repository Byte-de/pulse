import SwiftUI

/// "Token Usage" card: Today / This Month across Input · Output · Cache
/// (· Cost), plus the per-model share breakdown.
struct TokenUsageCard: View {
    let report: TokenUsageReport
    let accent: Color

    private var maxShare: Double { max(report.modelBreakdown.map(\.share).max() ?? 0, 1) }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                CardTitleRow(systemImage: "number", title: "Token Usage") { EmptyView() }

                // Flexible columns so the table fills the card's full width:
                // fixed label column, then equal-width right-aligned numerics.
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        labelCell("")
                        header("Input")
                        header("Output")
                        header("Cache")
                        if report.showsCost { header("Cost") }
                    }
                    Divider().overlay(PulseColor.hairline.opacity(0.5))
                    row(label: "Today", totals: report.today)
                    row(label: "This Month", totals: report.thisMonth)
                }

                if !report.modelBreakdown.isEmpty {
                    modelBreakdown
                }
            }
        }
    }

    private func labelCell(_ text: String) -> some View {
        Text(text)
            .font(Typo.tableLabel)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func row(label: String, totals: TokenTotals) -> some View {
        HStack(spacing: 8) {
            labelCell(label)
            value(Formatters.tokenCount(totals.input))
            value(Formatters.tokenCount(totals.output))
            value(Formatters.tokenCount(totals.cacheRead + totals.cacheWrite))
            if report.showsCost {
                value(totals.costUSD.map(Formatters.money) ?? "—")
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Typo.tableValue)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .animation(Motion.numberTick, value: text)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(report.modelBreakdown.prefix(4)) { share in
                HStack(spacing: 8) {
                    Text(share.model)
                        .font(Typo.tableLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 110, alignment: .leading)
                    Capsule()
                        .fill(PulseColor.trackFill)
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(accent.opacity(0.8))
                                    .frame(width: proxy.size.width * share.share / maxShare)
                                    .animation(Motion.gaugeFill, value: share.share)
                            }
                        }
                    Text(Formatters.percent(share.share))
                        .font(Typo.captionValue)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                        .contentTransition(.numericText(value: share.share))
                }
            }
            if report.modelBreakdown.count > 4 {
                Text("+\(report.modelBreakdown.count - 4) more")
                    .font(Typo.footer)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}
