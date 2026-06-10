import SwiftUI

/// The menu bar label: one compact two-row block per visible provider —
/// stacked 2+1 letter code, threshold-colored dot + session %, trend arrow +
/// delta. Width changes are rare by construction (monospaced digits, fixed
/// placeholders), so the status item never jitters.
struct StatusBarLabelView: View {
    let store: UsageStore
    let settings: SettingsStore
    let descriptors: [ProviderID: ProviderDescriptor]
    /// NSStatusItem cannot size itself from a hosted SwiftUI view — the
    /// controller sets `statusItem.length` from this measurement.
    var onWidthChange: (CGFloat) -> Void = { _ in }

    /// Enabled ∩ user-allowed ∩ recently active. Dormant or unconnected
    /// providers keep their tab but never occupy menu bar width.
    private var activeProviders: [ProviderID] {
        settings.visibleMenuBarProviders.filter { store.record(for: $0).isActiveRecently }
    }

    var body: some View {
        HStack(spacing: 8) {
            if settings.menuBarStyle == .icon || activeProviders.isEmpty {
                Image(nsImage: PulseIcons.byteMark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.primary)
            } else {
                ForEach(activeProviders) { id in
                    ProviderStatBlock(
                        code: descriptors[id]?.shortCode ?? id.rawValue.uppercased(),
                        record: store.record(for: id)
                    )
                }
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            onWidthChange(width)
        }
        .allowsHitTesting(false)
    }
}

private struct ProviderStatBlock: View {
    let code: String
    let record: ProviderRecord

    private var utilization: Double? { record.snapshot?.primary?.utilization }

    private var dotColor: Color {
        guard let utilization else { return Color.primary.opacity(0.25) }
        if record.isStale { return PulseColor.warnStrong }
        return PulseColor.threshold(utilization: utilization)
    }

    var body: some View {
        HStack(spacing: 2.5) {
            codeColumn
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2.5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .animation(Motion.staleTint, value: record.isStale)
                    Text(utilization.map(Formatters.percent) ?? "––")
                        .font(Typo.menuBarValue)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: utilization ?? 0))
                        .animation(Motion.numberTick, value: utilization)
                }
                trendRow
            }
        }
    }

    /// "CLA" rendered as "CL" over "A", matching the reference design.
    private var codeColumn: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(String(code.prefix(2)))
            Text(String(code.dropFirst(2)))
        }
        .font(Typo.menuBarCode)
        .tracking(0.5)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var trendRow: some View {
        if let trend = record.primaryTrend, utilization != nil {
            HStack(spacing: 1.5) {
                Image(systemName: trend.direction == .down ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size: 5.5, weight: .bold))
                    .opacity(trend.direction == .flat ? 0 : 1)
                Text(Formatters.deltaPercent(trend.delta))
                    .font(Typo.menuBarDelta)
                    .contentTransition(.numericText(value: abs(trend.delta)))
            }
            .foregroundStyle(PulseColor.trend(delta: trend.delta))
            .animation(Motion.iconSwap, value: trend.direction == .up)
        } else {
            Text("–")
                .font(Typo.menuBarDelta)
                .foregroundStyle(.secondary)
        }
    }
}
