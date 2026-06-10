import SwiftUI

/// "Updated 30s ago" row with the refresh affordance. The timestamp ticks every
/// second while visible; staleness shifts the dot/text amber → red (color only,
/// never an animation).
struct PanelFooter: View {
    let store: UsageStore
    let refresh: () -> Void

    /// Spinner + checkmark belong to MANUAL refreshes only (DESIGN §4.7).
    /// Automatic polls get the one-shot dot pulse — repeated icon motion on
    /// every poll would violate motion rule 9.
    private enum ManualPhase { case idle, spinning, confirmed }
    @State private var manualPhase: ManualPhase = .idle
    @State private var dotPulsed = false

    var body: some View {
        CardView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    let staleness = staleness(now: context.date)
                    Circle()
                        .fill(staleness.color)
                        .frame(width: 5, height: 5)
                        .opacity(dotPulsed ? 0.35 : 1)
                        .animation(Motion.staleTint, value: staleness.level)
                    Text(statusText(now: context.date))
                        .font(Typo.footer)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.numberTick, value: statusText(now: context.date))
                    Spacer()
                    refreshButton
                }
            }
        }
        .task(id: store.lastUpdated) {
            // refreshPulse: one subtle confirmation per successful auto-fetch.
            guard store.lastUpdated != nil, !Motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.4)) { dotPulsed = true }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeInOut(duration: 0.4)) { dotPulsed = false }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        switch manualPhase {
        case .spinning:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 24, height: 24)
                .transition(.blurReplace)
        case .confirmed:
            ThemedIcon(symbol: "checkmark", pointSize: 10)
                .foregroundStyle(PulseColor.ok)
                .frame(width: 24, height: 24)
                .transition(.blurReplace)
        case .idle:
            GhostIconButton(systemImage: "arrow.clockwise", help: "Refresh now (⌘R)", action: runManualRefresh)
                .transition(.blurReplace)
        }
    }

    private func runManualRefresh() {
        guard manualPhase == .idle else { return }
        refresh()
        Task {
            withAnimation(Motion.iconSwap) { manualPhase = .spinning }
            // Held ≥500ms so a fast fetch never flickers the spinner.
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(Motion.iconSwap) { manualPhase = .confirmed }
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(Motion.iconSwap) { manualPhase = .idle }
        }
    }

    private enum StalenessLevel { case fresh, stale, offline }

    private func staleness(now: Date) -> (level: StalenessLevel, color: Color) {
        guard let last = store.lastUpdated else { return (.fresh, .secondary) }
        let age = now.timeIntervalSince(last)
        if age >= 600 { return (.offline, PulseColor.critical) }
        if age >= 120 { return (.stale, PulseColor.warnStrong) }
        return (.fresh, PulseColor.ok)
    }

    private func statusText(now: Date) -> String {
        guard let last = store.lastUpdated else { return "Waiting for first update…" }
        return "Updated \(Formatters.relativeAge(of: last, now: now))"
    }
}

/// Bottom action bar: Open <Provider> · Settings · minimize (collapse the
/// panel back into the menu bar) · quit.
struct PanelBottomBar: View {
    let providerName: String
    let openProvider: () -> Void
    let openSettings: () -> Void
    let minimize: () -> Void
    let quit: () -> Void

    var body: some View {
        CardView {
            HStack(spacing: 4) {
                BarButton(title: "Open \(providerName)", tint: PulseColor.info, action: openProvider)
                Spacer()
                BarButton(title: "Settings", action: openSettings)
                GhostIconButton(systemImage: "minus", help: "Minimize — Pulse stays in the menu bar (esc)", action: minimize)
                GhostIconButton(systemImage: "xmark", help: "Quit Pulse (⌘Q)", action: quit)
            }
            .padding(-4)
        }
    }
}
