import SwiftUI

/// "Token Usage" card: Today / This Month across Input · Output · Cache
/// (· Cost), plus the per-model share breakdown.
///
/// When the source can see sub-agents (jcode records a `parent_id`; Claude Code
/// and pi never do), the row gains an indented "↳ sub-agents" line — and only
/// when that window's slice is non-zero, so an account whose harness cannot
/// produce sub-agents shows no row rather than a row of zeros. That line is
/// the **sub-agent share of the row above**, which already includes it — the
/// row is the total, not a main-only figure. Labelling the parent row "Today
/// (all)" makes the containment explicit, since a bare "Today" next to an
/// indented number reads as two things to add. 18.2% of jcode tokens were
/// sub-agent work when measured 2026-08-28, so the distinction is not academic.
/// The full main-vs-sub split lives in the analytics window; this card stays a
/// fast review.
struct TokenUsageCard: View {
    let report: TokenUsageReport
    let accent: Color

    private var maxShare: Double { max(report.modelBreakdown.map(\.share).max() ?? 0, 1) }

    /// Each window gates its own sub-agent line, so a month with sub-agent work
    /// and a day without shows one line, not one line and a row of zeros. The
    /// "(all)" suffix follows the same gate: it only earns its place on a row
    /// that actually has a slice underneath it.
    private var showsToday: Bool { TokenUsageReport.isSubAgentSliceVisible(report.todaySubAgent) }
    private var showsMonth: Bool { TokenUsageReport.isSubAgentSliceVisible(report.thisMonthSubAgent) }

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
                    row(label: showsToday ? "Today (all)" : "Today", totals: report.today)
                    if showsToday {
                        subAgentRow(totals: report.todaySubAgent)
                    }
                    row(label: showsMonth ? "Month (all)" : "This Month", totals: report.thisMonth)
                    if showsMonth {
                        subAgentRow(totals: report.thisMonthSubAgent)
                    }
                }

                if !report.modelBreakdown.isEmpty {
                    modelBreakdown
                }
            }
        }
    }

    /// Width of the row-label column. Sized to the longest label the card can
    /// show, "↳ sub-agents": at 72pt it wrapped to two lines mid-word
    /// ("↳ sub-" / "agents"), which doubled that row's height and broke the
    /// table's alignment with the neighbouring provider column.
    private static let labelWidth: CGFloat = 88

    private func labelCell(_ text: String) -> some View {
        Text(text)
            .font(Typo.tableLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: Self.labelWidth, alignment: .leading)
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

    /// Sub-agent slice of the row above: secondary styling and an indent mark,
    /// so it reads as a breakdown of that row rather than a total to add to it.
    private func subAgentRow(totals: TokenTotals) -> some View {
        HStack(spacing: 8) {
            Text("↳ sub-agents")
                .font(Typo.footer)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.labelWidth, alignment: .leading)
            secondaryValue(Formatters.tokenCount(totals.input))
            secondaryValue(Formatters.tokenCount(totals.output))
            secondaryValue(Formatters.tokenCount(totals.cacheRead + totals.cacheWrite))
            if report.showsCost {
                secondaryValue(totals.costUSD.map(Formatters.money) ?? "—")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sub-agents: \(totals.input) input, \(totals.output) output, "
                + "\(totals.cacheRead + totals.cacheWrite) cache, included in the row above"
        )
    }

    private func secondaryValue(_ text: String) -> some View {
        Text(text)
            .font(Typo.footer)
            .foregroundStyle(.secondary)
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
