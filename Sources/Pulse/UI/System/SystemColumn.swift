import SwiftUI

/// Machine stats column, pinned left of the providers.
///
/// Exists because the panel's whole job changed once agents started running
/// locally: a provider limit says whether the *account* can keep going, and
/// this says whether the *Mac* can. Deliberately narrower than a provider
/// column - it is a glanceable sidebar, not a monitoring app.
struct SystemColumn: View {
    let monitor: SystemMonitor
    let showProcesses: Bool
    /// Simple-view form: CPU and memory only, each reduced to headline, bar and
    /// graph. The P/E split, load average, disk card and process tables are all
    /// diagnostics - they answer "why is it slow", which is a question you ask
    /// in the full view, after this column has told you that it *is* slow.
    ///
    /// Disk survives as a single red line above 90%, and only above 90%,
    /// because a full boot volume kills a long agent run with less warning than
    /// anything else here.
    var isCompact = false

    var body: some View {
        VStack(spacing: Layout.cardGap) {
            SystemColumnHeader(sample: monitor.sample, hasSample: monitor.hasSample)

            CPUCard(
                sample: monitor.sample,
                history: monitor.cpuHistory,
                hasSample: monitor.hasSample,
                isCompact: isCompact
            )
            MemoryCard(sample: monitor.sample, history: monitor.memoryHistory, isCompact: isCompact)

            if isCompact {
                DiskWarningLine(sample: monitor.sample)
            } else {
                StorageCard(sample: monitor.sample)
            }

            if showProcesses, !isCompact {
                TopProcessesCard(
                    title: "Top by CPU",
                    systemImage: "gauge.with.needle",
                    processes: monitor.sample.topProcesses,
                    metric: .cpu
                )
                TopProcessesCard(
                    title: "Top by RAM",
                    systemImage: "memorychip",
                    processes: monitor.sample.topMemoryProcesses,
                    metric: .memory
                )
            }
            // NO trailing Spacer. This column is measured, not scrolled: its
            // height is reported up to PanelController, which resizes the
            // window to it. A Spacer here expands to the *proposed* height,
            // i.e. the window's current height, so the reported height becomes
            // the window height and the panel can never shrink again — it
            // stays at whatever it once grew to, with dead space under the
            // cards. Measured 2026-09-01 with an offscreen NSHostingView:
            // content 338pt reported as 560 in a 560pt window and 1200 in a
            // 1200pt window; without the Spacer, 338 in both. HStack(alignment:
            // .top) already top-aligns the columns, so the Spacer bought
            // nothing. See scripts/check-panel-height.py.
        }
        .frame(width: Layout.systemColumnWidth)
        // Ref-counted polling: the sampler runs only while this column is on
        // screen, so a closed panel costs nothing.
        .task {
            monitor.addSubscriber()
            // Kick one reading immediately; the loop's first tick establishes
            // the CPU baseline and reports 0 until the second.
            await monitor.poll()
        }
        .onDisappear { monitor.removeSubscriber() }
    }
}

/// Header matching `ProviderColumnHeader`'s pill so the sidebar reads as a
/// peer of the provider columns, not as chrome.
private struct SystemColumnHeader: View {
    let sample: SystemSample
    let hasSample: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text("This Mac")
                .font(Typo.tabLabel)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if sample.thermal != .nominal {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(thermalColor)
                    .help("Thermal state: \(thermalLabel). The system is throttling.")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.tabBarHeight)
        .background(Capsule().fill(PulseColor.trackFill))
        .help(hasSample ? headline : "Sampling…")
    }

    /// One dot for "can this Mac take more work": the worst of CPU, memory
    /// pressure, disk and thermal state, since any one of them alone can be the
    /// thing that makes another agent a bad idea. Disk is in here because a
    /// volume at 97% kills a long run just as dead as an exhausted CPU, and it
    /// is the failure that gives the least warning.
    private var statusColor: Color {
        if sample.memoryPressure == .critical || sample.thermal == .critical || sample.diskUtilization >= 95 {
            return PulseColor.critical
        }
        if sample.memoryPressure == .warning || sample.thermal == .serious || sample.diskUtilization >= 90 {
            return PulseColor.warn
        }
        return PulseColor.threshold(utilization: max(sample.cpuTotal, sample.loadUtilization, performancePressure))
    }

    /// Saturated Performance cores count as CPU pressure even when the
    /// aggregate is comfortable: the E-cores being free does not help a build
    /// that is waiting on a fast core.
    private var performancePressure: Double {
        guard let performance = sample.cpuPerformance, sample.hasCoreSplit else { return 0 }
        return performance
    }

    private var thermalColor: Color {
        switch sample.thermal {
        case .critical: PulseColor.critical
        case .serious: PulseColor.warnStrong
        default: PulseColor.warn
        }
    }

    private var thermalLabel: String {
        switch sample.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private var headline: String {
        "CPU \(Formatters.percent(sample.cpuTotal)) · RAM \(Formatters.percent(sample.memoryUtilization)) · load \(String(format: "%.2f", sample.load1)) on \(sample.coreCount) cores"
    }
}

/// CPU: headline percent, user/system split, sparkline, load average.
private struct CPUCard: View {
    let sample: SystemSample
    let history: [Double]
    let hasSample: Bool
    var isCompact = false

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "cpu", title: "CPU") {
                    Text(hasSample ? Formatters.percent(sample.cpuTotal) : "—")
                        .font(Typo.gaugeValue)
                        .contentTransition(.numericText(value: sample.cpuTotal))
                        // NO `.animation(_:value:)` on a value that changes
                        // on every sample. The percentage moves each tick, so
                        // the animation restarts before the previous one ends,
                        // and a permanently in-flight animation makes SwiftUI
                        // redraw this layer tree at DISPLAY rate rather than
                        // once per sample. Measured on an M4: the sidebar cost
                        // ~10% of a core with these two modifiers and ~3%
                        // without them - and PanelFooter had the same bug at
                        // 1-second cadence for 34%. See the comment there, and
                        // scripts/check-timeline-animation.py, which fails CI
                        // if the clock-driven form comes back.
                        // `contentTransition` still animates the digit change,
                        // driven by the value actually changing.
                }

                // Always `.used`: a CPU bar is consumption, and inverting it
                // with the provider gauges would mean a full bar reads as
                // "idle" on one card and "pinned" on the next.
                GaugeBar(utilization: sample.cpuTotal, direction: .used)

                Sparkline(values: history, color: PulseColor.threshold(utilization: sample.cpuTotal))
                    .frame(height: isCompact ? 34 : 26)

                // The P/E split, when the machine has one. The aggregate hides
                // the case that actually matters: on a 4P+6E Mac, a build
                // pegging all four P-cores reads as ~40% overall, which looks
                // like headroom and is not.
                if sample.hasCoreSplit, !isCompact {
                    VStack(spacing: 4) {
                        clusterRow(
                            label: "P",
                            count: sample.performanceCoreCount,
                            busy: sample.cpuPerformance
                        )
                        clusterRow(
                            label: "E",
                            count: sample.efficiencyCoreCount,
                            busy: sample.cpuEfficiency
                        )
                    }
                    .help("Performance and Efficiency cores, measured separately. The combined percentage can look comfortable while every fast core is already taken, which is what decides whether another agent gets real cycles.")
                }

                HStack(spacing: 4) {
                    if !isCompact {
                        Text("usr \(Formatters.percent(sample.cpuUser))")
                        Text("·")
                        Text("sys \(Formatters.percent(sample.cpuSystem))")
                    } else {
                        Text("load")
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "%.2f", sample.load1))
                        .foregroundStyle(loadColor)
                    Text("/ \(sample.coreCount)c")
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .help("Load average 1m / 5m / 15m: \(loadText). Above \(sample.coreCount) means more runnable work than cores.")
            }
        }
    }

    private var loadColor: Color {
        PulseColor.threshold(utilization: sample.loadUtilization)
    }

    /// One cluster: "P 4c ▓▓▓▓░ 92%". Compact enough that two of them cost less
    /// vertical space than one more card would.
    @ViewBuilder
    private func clusterRow(label: String, count: Int, busy: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)
                .frame(width: 9, alignment: .leading)
            Text("\(count)c")
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)

            GaugeBar(utilization: busy ?? 0, direction: .used)

            // An em dash rather than 0% for the first tick, when there is no
            // delta yet: showing 0% would claim the cluster is idle.
            Text(busy.map(Formatters.percent) ?? "—")
                .font(Typo.captionValue)
                .foregroundStyle(busy.map { PulseColor.threshold(utilization: $0) } ?? .secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var loadText: String {
        String(format: "%.2f / %.2f / %.2f", sample.load1, sample.load5, sample.load15)
    }
}

/// Memory: used/total gauge, history, kernel pressure, compressed and swap.
private struct MemoryCard: View {
    let sample: SystemSample
    let history: [Double]
    var isCompact = false

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "memorychip", title: "Memory") {
                    Text(Formatters.percent(sample.memoryUtilization))
                        .font(Typo.gaugeValue)
                        .contentTransition(.numericText(value: sample.memoryUtilization))
                        // NO `.animation(_:value:)` on a value that changes
                        // on every sample. The percentage moves each tick, so
                        // the animation restarts before the previous one ends,
                        // and a permanently in-flight animation makes SwiftUI
                        // redraw this layer tree at DISPLAY rate rather than
                        // once per sample. Measured on an M4: the sidebar cost
                        // ~10% of a core with these two modifiers and ~3%
                        // without them - and PanelFooter had the same bug at
                        // 1-second cadence for 34%. See the comment there, and
                        // scripts/check-timeline-animation.py, which fails CI
                        // if the clock-driven form comes back.
                        // `contentTransition` still animates the digit change,
                        // driven by the value actually changing.
                }

                GaugeBar(
                    utilization: sample.memoryUtilization,
                    color: pressureColor,
                    direction: .used
                )
                .help("Used \(Formatters.bytes(sample.memoryUsed)) of \(Formatters.bytes(sample.memoryTotal)). Kernel memory pressure: \(sample.memoryPressure.label).")

                // Same treatment as CPU: the number says how full memory is,
                // the shape says whether it is still climbing - which is the
                // part that decides whether to start another agent.
                Sparkline(values: history, color: pressureColor)
                    .frame(height: isCompact ? 34 : 26)

                HStack(spacing: 4) {
                    Text(Formatters.bytes(sample.memoryUsed))
                        .foregroundStyle(.primary)
                    Text("/ \(Formatters.bytes(sample.memoryTotal))")
                    Spacer(minLength: 4)
                    if sample.memoryPressure != .normal {
                        Text(sample.memoryPressure.label)
                            .foregroundStyle(pressureColor)
                    }
                }
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)

                // Compressed is dropped in the compact form and swap is not:
                // compression is normal housekeeping, swap in use while an
                // agent runs is the thing that makes everything feel slow.
                HStack(spacing: 4) {
                    if !isCompact {
                        Text("compressed \(Formatters.bytes(sample.memoryCompressed))")
                        Spacer(minLength: 4)
                    }
                    Text("swap \(Formatters.bytes(sample.swapUsed))")
                        .foregroundStyle(sample.swapUsed > 0 ? AnyShapeStyle(swapColor) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .trailing)
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .help("Compressed memory and swap both mean the machine ran out of room for the pages it wanted. Swap in use while an agent runs is the first thing to look at when everything feels slow.")
            }
        }
    }

    /// Pressure, not the ratio, drives the colour: macOS keeps memory nominally
    /// full of cache on purpose, so a red bar at 85% "used" with normal
    /// pressure would cry wolf on every healthy Mac.
    private var pressureColor: Color {
        switch sample.memoryPressure {
        case .normal: PulseColor.threshold(utilization: sample.memoryUtilization)
        case .warning: PulseColor.warnStrong
        case .critical: PulseColor.critical
        }
    }

    private var swapColor: Color {
        sample.swapUsed > 2_000_000_000 ? PulseColor.critical : PulseColor.warn
    }
}

/// Disk free on the boot volume - the thing that silently kills a long agent
/// run that is writing logs, caches and node_modules.
///
/// No sparkline here on purpose: free space moves in gigabytes over hours, so a
/// two-minute history would be a flat line on every healthy machine and would
/// imply the number is worth watching second by second. The reclaimable figure
/// is the useful extra instead.
private struct StorageCard: View {
    let sample: SystemSample

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "internaldrive", title: "Disk") {
                    Text(Formatters.bytes(sample.diskFree))
                        .font(Typo.gaugeValue)
                }

                GaugeBar(utilization: sample.diskUtilization, direction: .used)

                HStack {
                    Text("free of \(Formatters.bytes(sample.diskTotal))")
                    Spacer(minLength: 4)
                    Text(Formatters.percent(sample.diskUtilization) + " used")
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)

                // Only shown when there is something to reclaim: a permanent
                // "reclaimable 0 B" row would be noise on a machine with no
                // cache to evict.
                if sample.diskPurgeable > 0 {
                    HStack {
                        Text("reclaimable cache")
                        Spacer(minLength: 4)
                        Text(Formatters.bytes(sample.diskPurgeable))
                            .foregroundStyle(.primary)
                    }
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .help("Caches, snapshots and downloads macOS will evict when something needs the space. Counted inside the free figure above, so it is already promised to you - but it is not empty space today.")
                }
            }
        }
    }
}

/// Disk in the simple view: nothing at all until the boot volume passes 90%,
/// then one coloured line.
///
/// A permanent disk card there would be a number that does not move and does
/// not need watching, spending a third of the column. But the failure it warns
/// about is the one that gives the least warning - a volume at 97% ends a long
/// run mid-write - so it earns its line the moment it becomes true, and stays
/// invisible the rest of the time.
private struct DiskWarningLine: View {
    let sample: SystemSample

    var body: some View {
        if sample.diskUtilization >= 90 {
            HStack(spacing: 5) {
                ThemedIcon(symbol: "exclamationmark.triangle", pointSize: 9, weight: .semibold)
                Text("Disk \(Formatters.percent(sample.diskUtilization)) full")
                Spacer(minLength: 4)
                Text(Formatters.bytes(sample.diskFree) + " free")
            }
            .font(Typo.caption)
            .foregroundStyle(sample.diskUtilization >= 95 ? PulseColor.critical : PulseColor.warnStrong)
            .padding(.horizontal, 4)
            .help("Boot volume is nearly full. A long agent run writing logs, caches or node_modules can fail on this before it hits any provider limit. Full detail in the everything view.")
        }
    }
}

/// The few processes actually eating the machine right now, ranked by one
/// metric. Two instances of this sit in the column - CPU and memory - because
/// the two rankings answer different questions: what is burning the machine
/// *now* versus what is holding the RAM a new agent would need.
private struct TopProcessesCard: View {
    /// Which metric this card ranks by, and the ONLY number it shows.
    ///
    /// The secondary metric was shown dimmed beside it at first, as context.
    /// That was wrong: Activity Monitor's CPU tab has no Memory column either,
    /// the neighbouring card already carries the other ranking, and in a 210pt
    /// column the third value is paid for by truncating the process name -
    /// which is the only thing identifying the row. Both figures are still in
    /// the tooltip.
    enum Metric { case cpu, memory }

    let title: String
    let systemImage: String
    let processes: [ProcessSample]
    let metric: Metric

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: systemImage, title: title) { EmptyView() }

                if processes.isEmpty {
                    Text("Sampling…")
                        .font(Typo.footer)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(processes) { process in
                            row(process)
                        }
                    }
                }
            }
        }
    }

    private func row(_ process: ProcessSample) -> some View {
        HStack(spacing: 6) {
            Text(ProcessSample.displayName(process.name))
                .font(Typo.tableLabel)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The name identifies the row, so it takes the space the
                // second metric used to occupy.
                .layoutPriority(1)

            Spacer(minLength: 4)

            Text(primaryText(process))
                .font(Typo.captionValue)
                .foregroundStyle(primaryColor(process))
                .lineLimit(1)
                .fixedSize()
        }
        .help(helpText(process))
    }

    /// Both figures live here, since the row itself now shows only the ranked
    /// one. Names the measurement explicitly, because "memory" is ambiguous on
    /// macOS and the two available numbers differ by up to 11x.
    private func helpText(_ process: ProcessSample) -> String {
        let memory = process.memoryIsApproximate
            ? "\(Formatters.bytes(process.memory)) resident (footprint unavailable for this process)"
            : "\(Formatters.bytes(process.memory)) memory footprint"
        return "PID \(process.pid) · \(process.name) · \(Formatters.percent(process.cpu)) of one core · \(memory)"
    }

    private func primaryText(_ process: ProcessSample) -> String {
        switch metric {
        case .cpu: Formatters.percent(process.cpu)
        // A leading "~" for a row whose footprint the kernel refused, so an RSS
        // fallback is never shown as if it were the same measurement.
        case .memory:
            (process.memoryIsApproximate ? "~" : "") + Formatters.compactBytes(process.memory)
        }
    }

    /// Only the CPU ranking is threshold-coloured. There is no equivalent
    /// "too much" line for a single process's memory - a 4 GB browser is
    /// normal on a 32 GB Mac and alarming on an 8 GB one - and colouring it
    /// against an invented threshold would signal a problem that is not there.
    private func primaryColor(_ process: ProcessSample) -> Color {
        switch metric {
        case .cpu: PulseColor.threshold(utilization: process.cpu)
        case .memory: .primary
        }
    }
}
