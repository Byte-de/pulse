import Darwin
import Foundation
import Observation

/// One reading of the local machine's resources.
///
/// Deliberately a plain value: the sampler produces it off the main actor, the
/// UI only ever renders one. Every byte count is raw bytes so formatting stays
/// a UI concern.
struct SystemSample: Sendable, Equatable {
    /// 0...100 across all cores combined (what Activity Monitor's "% CPU"
    /// column sums to divided by core count).
    var cpuTotal: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var coreCount: Int = 1

    /// Busy percentage of the Performance cores only, or nil on a machine with
    /// no such split (Intel, or a future topology we cannot classify).
    ///
    /// This is the number the aggregate hides. On an M4 (4 P + 6 E) a build
    /// that pegs all four P-cores while the E-cores idle reads as ~40% overall,
    /// which looks like plenty of headroom and is not: the cores that finish
    /// work fast are already gone.
    var cpuPerformance: Double?
    /// Busy percentage of the Efficiency cores only.
    var cpuEfficiency: Double?
    var performanceCoreCount: Int = 0
    var efficiencyCoreCount: Int = 0

    /// True when the P/E split is real and worth showing.
    var hasCoreSplit: Bool { cpuPerformance != nil && performanceCoreCount > 0 }

    /// Unix load averages. Read against `coreCount`: load == cores means the
    /// run queue is exactly saturated, which is the number that actually
    /// predicts whether one more local agent will thrash.
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0

    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var memoryCompressed: Int64 = 0
    var memoryPressure: MemoryPressure = .normal

    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0

    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    /// Reclaimable space: caches, snapshots and downloads macOS would evict on
    /// demand. It is `...ForImportantUsage - ...AvailableCapacity`, i.e. the gap
    /// between what the system promises an important write and what is free
    /// right now. Worth showing because "11 GB free" and "11 GB free of which
    /// 0.8 GB is cache the system will hand back" are different situations.
    var diskPurgeable: Int64 = 0

    var thermal: ProcessInfo.ThermalState = .nominal

    /// Heaviest processes by CPU, already trimmed to what the card shows.
    var topProcesses: [ProcessSample] = []
    /// Heaviest processes by resident memory. A separate list, not a re-sort of
    /// `topProcesses`: the two rankings overlap by only a row or two in
    /// practice, and sorting a CPU top-5 by memory would just show the memory
    /// of whatever happened to be busy.
    var topMemoryProcesses: [ProcessSample] = []

    /// Utilization 0...100 for the gauges, guarding division by an unknown total.
    var memoryUtilization: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(100, Double(memoryUsed) / Double(memoryTotal) * 100)
    }

    var diskUtilization: Double {
        guard diskTotal > 0 else { return 0 }
        return min(100, Double(diskTotal - diskFree) / Double(diskTotal) * 100)
    }

    /// Load as a share of the machine's parallelism, capped for display.
    var loadUtilization: Double {
        guard coreCount > 0 else { return 0 }
        return min(100, load1 / Double(coreCount) * 100)
    }

    /// The kernel's own memory-pressure verdict, which is NOT the same as the
    /// used/total ratio: macOS keeps memory nominally "full" of cache and only
    /// reports warn/critical once it starts fighting for pages.
    enum MemoryPressure: Int, Sendable, Equatable {
        case normal = 1
        case warning = 2
        case critical = 4

        var label: String {
            switch self {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
        }
    }
}

/// One process row: pid, command, CPU share and memory.
struct ProcessSample: Sendable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    /// Percent of ONE core, exactly as `ps` reports it, so a busy compiler can
    /// legitimately exceed 100.
    var cpu: Double
    /// Memory as Activity Monitor's "Memory" column reports it: the process's
    /// physical footprint.
    ///
    /// NOT resident set size. `ps` RSS is a different measurement and it
    /// understates badly and inconsistently - measured on this Mac: Safari
    /// 68 MB RSS against 800 MB footprint (11.6x), a Gmail tab 526 MB against
    /// 1898 MB (3.6x), while jcode read 377 MB against 335 MB (0.89x). Because
    /// the ratio varies per process, ranking on RSS does not merely scale the
    /// numbers down, it puts the rows in the WRONG ORDER and hides the
    /// multi-gigabyte processes entirely.
    var memory: Int64
    /// True when the footprint could not be read (root-owned processes deny
    /// `proc_pid_rusage`) and `memory` therefore carries RSS instead. Surfaced
    /// so an approximate figure is never presented as an exact one.
    var memoryIsApproximate: Bool = false

    /// Short label for a 210pt column.
    ///
    /// macOS process names are often reverse-DNS bundle ids
    /// (`com.apple.WebKit.WebContent`), and truncating one from the middle
    /// produces `com....ntent`, which identifies nothing. The informative part
    /// is the tail, so the domain prefix is dropped instead.
    static func displayName(_ raw: String) -> String {
        guard raw.hasPrefix("com.") || raw.hasPrefix("org.") || raw.hasPrefix("net.") else {
            return raw
        }
        let parts = raw.split(separator: ".")
        // "com.apple.WebKit.WebContent" -> "WebKit.WebContent": the last two
        // components, since the final one alone ("WebContent") loses which
        // subsystem it belongs to.
        guard parts.count > 3 else {
            return parts.dropFirst(2).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }
}

/// Reads host counters. An actor because CPU percentage is a delta between two
/// readings, so the previous tick's ticks are state that must not be raced.
actor SystemSampler {
    private var previousTicks: CPUTicks?
    private var previousCoreTicks: [CPUTicks]?
    /// Cumulative CPU ticks per pid from the previous table, and when it was
    /// taken. A per-process percentage is a delta, so both are required.
    private var previousProcessCPU: [Int32: UInt64] = [:]
    private var previousProcessSampleTime: UInt64?
    /// Last disk reading and when it was taken. Cached because the call is
    /// three orders of magnitude more expensive than the rest of a tick.
    private var cachedDisk: (free: Int64, total: Int64, purgeable: Int64)?
    private var cachedDiskAt: UInt64?

    /// Cached core topology. Fixed for the life of the process, and two sysctl
    /// calls per tick is pure waste.
    private lazy var topology = CoreTopology.detect()

    /// How the machine's cores split into Performance and Efficiency clusters,
    /// and which indices in `host_processor_info`'s array belong to each.
    ///
    /// MEASURED, NOT ASSUMED: on this M4, `hw.perflevel0` is named
    /// "Performance" with 4 cores and `hw.perflevel1` is "Efficiency" with 6,
    /// but `host_processor_info` lists the EFFICIENCY cores first - indices 0-5
    /// are the E-cores and 6-9 are the P-cores. Verified in both directions by
    /// pinning spin loops: `.background` QoS work landed on 0-3 (E-cores, where
    /// macOS confines it) and `.userInteractive` work landed on 6-9. Assuming
    /// perflevel0 maps to the first indices gives a plausible, wrong answer
    /// that reports the P-cores idle while a build saturates them.
    ///
    /// Because that ordering is undocumented, the split is derived from the
    /// per-level core COUNTS and the observed convention, and the whole feature
    /// degrades to nil rather than guessing when the counts do not add up.
    struct CoreTopology {
        var performanceIndices: Range<Int> = 0..<0
        var efficiencyIndices: Range<Int> = 0..<0
        var isSplit: Bool = false

        static func detect() -> CoreTopology {
            let total = ProcessInfo.processInfo.activeProcessorCount
            guard sysctlInt("hw.nperflevels") == 2,
                  let first = sysctlInt("hw.perflevel0.logicalcpu"),
                  let second = sysctlInt("hw.perflevel1.logicalcpu"),
                  first > 0, second > 0, first + second == total
            else {
                return CoreTopology()
            }

            // perflevel0 is the FASTER cluster (named "Performance" here), but
            // it occupies the LAST indices in the processor-info array. Read the
            // names rather than trusting the order, so a future Apple Silicon
            // variant with the naming reversed is classified correctly instead
            // of inverted.
            let firstIsPerformance = sysctlString("hw.perflevel0.name")?
                .localizedCaseInsensitiveContains("performance") ?? true

            let performanceCount = firstIsPerformance ? first : second
            let efficiencyCount = firstIsPerformance ? second : first

            // Efficiency cluster occupies the low indices, performance the high
            // ones - the ordering verified above.
            return CoreTopology(
                performanceIndices: efficiencyCount..<total,
                efficiencyIndices: 0..<efficiencyCount,
                isSplit: performanceCount > 0 && efficiencyCount > 0
            )
        }

        static func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }

        static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            // sysctl returns a NUL-terminated C string; the terminator has to
            // go before decoding or it lands inside the Swift String.
            let bytes = buffer.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 { user &+ system &+ idle &+ nice }
    }

    /// Number of process rows kept per card. Five is what fits a 210pt column
    /// without the card becoming a scroll surface.
    private let processLimit = 5

    /// Per-phase timings from the last `sample()`, for the --trace-ticks probe.
    private(set) var lastTimings = ""

    func sample(includeProcesses: Bool = true) -> SystemSample {
        var phases: [String] = []
        func phase(_ name: String, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            phases.append(String(format: "%@=%.1f", name, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        }
        defer { lastTimings = phases.joined(separator: " ") }

        var result = SystemSample()
        result.coreCount = ProcessInfo.processInfo.activeProcessorCount
        result.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        result.thermal = ProcessInfo.processInfo.thermalState

        phase("cpu") { applyCPU(to: &result) }
        phase("mem") { applyMemory(to: &result) }
        phase("load") { applyLoad(to: &result) }
        phase("swap") { applySwap(to: &result) }
        phase("disk") { applyDisk(to: &result) }
        if includeProcesses {
            var all: [ProcessSample] = []
            phase("proctable") { all = readProcessTable() }
            phase("rank") {
                result.topProcesses = Self.top(all, by: { $0.cpu }, limit: processLimit)
                result.topMemoryProcesses = Self.top(all, by: { Double($0.memory) }, limit: processLimit)
            }
        }
        return result
    }

    // MARK: - CPU

    private func applyCPU(to sample: inout SystemSample) {
        // The per-core split MUST be attempted before the aggregate's
        // early return below. It keeps its own baseline, and leaving it after
        // that `guard` meant the first call never captured one, so the second
        // call still had nothing to diff against and the split silently never
        // appeared - the whole feature reduced to a permanent nil.
        applyCoreSplit(to: &sample)

        guard let ticks = Self.readCPUTicks() else { return }
        defer { previousTicks = ticks }

        // The first reading has no baseline. Reporting the since-boot average
        // there would show a number that is real but answers a different
        // question ("was this Mac busy this month"), so it stays at zero for
        // one tick instead.
        guard let previous = previousTicks else { return }

        let deltaTotal = Double(ticks.total &- previous.total)
        guard deltaTotal > 0 else { return }

        let user = Double((ticks.user &- previous.user) &+ (ticks.nice &- previous.nice))
        let system = Double(ticks.system &- previous.system)
        sample.cpuUser = min(100, user / deltaTotal * 100)
        sample.cpuSystem = min(100, system / deltaTotal * 100)
        sample.cpuTotal = min(100, sample.cpuUser + sample.cpuSystem)
    }

    /// Per-cluster busy percentages, so a saturated Performance cluster is
    /// visible behind a comfortable-looking aggregate.
    private func applyCoreSplit(to sample: inout SystemSample) {
        guard topology.isSplit else { return }
        sample.performanceCoreCount = topology.performanceIndices.count
        sample.efficiencyCoreCount = topology.efficiencyIndices.count

        guard let current = Self.readPerCoreTicks() else { return }
        defer { previousCoreTicks = current }
        guard let previous = previousCoreTicks,
              previous.count == current.count,
              // A core coming online (or a topology change) invalidates the
              // index mapping, so the reading is skipped rather than attributed
              // to the wrong cluster.
              current.count == topology.performanceIndices.count + topology.efficiencyIndices.count
        else { return }

        func busy(_ indices: Range<Int>) -> Double? {
            var busyTicks = 0.0
            var totalTicks = 0.0
            for index in indices where index < current.count {
                let deltaTotal = Double(current[index].total &- previous[index].total)
                guard deltaTotal > 0 else { continue }
                let idle = Double(current[index].idle &- previous[index].idle)
                busyTicks += deltaTotal - idle
                totalTicks += deltaTotal
            }
            guard totalTicks > 0 else { return nil }
            return min(100, max(0, busyTicks / totalTicks * 100))
        }

        sample.cpuPerformance = busy(topology.performanceIndices)
        sample.cpuEfficiency = busy(topology.efficiencyIndices)
    }

    /// One `CPUTicks` per logical core. The array is kernel-allocated and MUST
    /// be handed back with `vm_deallocate`, or the app leaks a page per tick.
    private static func readPerCoreTicks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { index in
            CPUTicks(
                user: UInt64(info[index * stride + Int(CPU_STATE_USER)]),
                system: UInt64(info[index * stride + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[index * stride + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[index * stride + Int(CPU_STATE_NICE)])
            )
        }
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    // MARK: - Memory

    private func applyMemory(to sample: inout SystemSample) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // `vm_kernel_page_size` is a global var and therefore not
        // concurrency-safe under Swift 6; `host_page_size` asks the kernel for
        // the same number through a call.
        var rawPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS else { return }
        let pageSize = Int64(rawPageSize)
        // Activity Monitor's "Memory Used": app memory (internal, minus what is
        // purgeable) + wired + compressed. Plain `total - free` would report a
        // permanently near-full Mac, because the kernel keeps freed pages as
        // cache on purpose.
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let wiredPages = Int64(stats.wire_count)
        let compressedPages = Int64(stats.compressor_page_count)
        sample.memoryUsed = max(0, (appPages + wiredPages + compressedPages) * pageSize)
        sample.memoryCompressed = compressedPages * pageSize
        sample.memoryPressure = Self.readMemoryPressure()
    }

    private static func readMemoryPressure() -> SystemSample.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return SystemSample.MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    // MARK: - Load, swap, disk

    private func applyLoad(to sample: inout SystemSample) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return }
        sample.load1 = loads[0]
        sample.load5 = loads[1]
        sample.load15 = loads[2]
    }

    private func applySwap(to sample: inout SystemSample) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        sample.swapUsed = Int64(usage.xsu_used)
        sample.swapTotal = Int64(usage.xsu_total)
    }

    /// Disk figures, refreshed far more slowly than everything else.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the number Finder shows,
    /// and it is EXPENSIVE: it routes through CacheDelete, which computes how
    /// much space the system could reclaim across the whole volume. Measured
    /// inside the running app it costs **15-26 ms**, against under 0.2 ms for
    /// every other phase of a tick combined. At a 3-second cadence that alone
    /// was ~35% of a core with the panel open, and it was the entire cost - a
    /// `sample` profile blamed SwiftUI layout, which was wrong.
    ///
    /// A standalone benchmark measured it at 0.7 ms and missed this completely,
    /// because the second call in a loop hits a warm cache. Only in-app
    /// per-phase timing showed the real figure. Benchmark the phase where it
    /// runs, not in isolation.
    ///
    /// Free space moves in gigabytes over hours, so a 60-second refresh loses
    /// nothing a user could perceive. The cached value is reused in between.
    private func applyDisk(to sample: inout SystemSample) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = cachedDisk,
           let taken = cachedDiskAt,
           Double(now - taken) / 1_000_000_000 < Self.diskRefreshInterval {
            sample.diskFree = cached.free
            sample.diskTotal = cached.total
            sample.diskPurgeable = cached.purgeable
            return
        }

        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ]) else { return }

        // Reading the HOME directory, not "/": on APFS the root is a read-only
        // system snapshot, so `df /` reports 51% while the data volume holding
        // the user's files is at 97%. A clean, plausible, wrong answer.
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        // The difference between the two available-capacity keys IS the
        // reclaimable cache; there is no direct "purgeable" key.
        let immediatelyFree = Int64(values.volumeAvailableCapacity ?? 0)
        let purgeable = max(0, free - immediatelyFree)

        cachedDisk = (free: free, total: total, purgeable: purgeable)
        cachedDiskAt = now
        sample.diskFree = free
        sample.diskTotal = total
        sample.diskPurgeable = purgeable
    }

    /// Seconds between real disk reads. See `applyDisk` for why this is not the
    /// tick interval.
    private static let diskRefreshInterval: Double = 60

    // MARK: - Processes

    /// Full process table with no subprocess: one `sysctl(KERN_PROC_ALL)` for
    /// pids and names, then one `proc_pid_rusage` per pid for memory and CPU.
    ///
    /// WHY NOT `ps`: spawning it measured at **82-100 ms per tick** on this
    /// machine, against **0.45 ms** for the syscall pair - about 180x. The
    /// sidebar samples every 2 s while the panel is open, so the spawn alone was
    /// ~4% of a core sustained, plus a fork+exec of a 600-process table 30 times
    /// a minute. That was the single largest cost in the whole feature and none
    /// of it bought anything the kernel does not hand over directly.
    ///
    /// The reason `ps` was reached for first: rusage reports CUMULATIVE cpu
    /// time, not a percentage, so a per-pid delta between ticks is needed. That
    /// bookkeeping is `previousProcessCPU` below, and it is worth it.
    ///
    /// One pass serves both cards, so a process cannot appear with disagreeing
    /// figures in the two lists at the same moment.
    /// Internal rather than private so a verifier can assert on the FULL table.
    /// The cards are top-5 lists and a rusage-denied row reports zero for both
    /// metrics, so it can never place in one - meaning the approximate flag is
    /// unobservable from the cards alone and went untested for a whole session.
    func readProcessTable() -> [ProcessSample] {
        let entries = Self.allProcesses()
        guard !entries.isEmpty else { return [] }

        let now = DispatchTime.now().uptimeNanoseconds
        // Elapsed wall time since the last table, which is what a CPU
        // percentage is measured against.
        let elapsedNanos = previousProcessSampleTime.map { Double(now &- $0) } ?? 0
        defer { previousProcessSampleTime = now }

        var currentCPU: [Int32: UInt64] = [:]
        currentCPU.reserveCapacity(entries.count)
        var rows: [ProcessSample] = []
        rows.reserveCapacity(entries.count)

        for entry in entries {
            var row = ProcessSample(pid: entry.pid, name: entry.name, cpu: 0, memory: 0)

            if let usage = Self.processUsage(entry.pid) {
                row.memory = usage.footprint
                currentCPU[entry.pid] = usage.cpuTicks

                // A percentage needs two readings. Without a baseline the row
                // reports 0 rather than a since-launch average, which is a real
                // number answering a different question.
                if elapsedNanos > 0, let previous = previousProcessCPU[entry.pid] {
                    // ri_user_time / ri_system_time are in MACH TICKS on Apple
                    // Silicon, NOT nanoseconds. See `machTicksToNanos`.
                    let usedNanos = Double(usage.cpuTicks &- previous) * Self.machTicksToNanos
                    row.cpu = max(0, usedNanos / elapsedNanos * 100)
                }
            } else {
                // Root-owned process: rusage is denied, so neither figure is
                // available. Marked so an unknown is never shown as a real
                // measurement.
                row.memoryIsApproximate = true
            }
            rows.append(row)
        }

        previousProcessCPU = currentCPU
        return rows
    }

    /// Nanoseconds per unit of `ri_user_time` / `ri_system_time`.
    ///
    /// THE FIELDS ARE NOT NANOSECONDS on Apple Silicon, despite reading like a
    /// duration. `mach_timebase_info` reports numer=125 denom=3 on this M4, so
    /// one unit is 41.667 ns. Treating them as nanoseconds under-reports every
    /// process by exactly that factor: `herdr` showed 0.5% against `ps`'s 20.4%,
    /// which is a perfectly plausible "quiet machine" reading and completely
    /// wrong. With the conversion applied the two agree to within noise
    /// (12.6% vs 12.4%).
    private static let machTicksToNanos: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Every live process's pid and short name, in one syscall.
    static func allProcesses() -> [(pid: Int32, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Processes can appear between the sizing call and the data call, so the
        // buffer is over-allocated rather than sized exactly; a short read would
        // silently truncate the table.
        var procs = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride + 32
        )
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var out: [(pid: Int32, name: String)] = []
        out.reserveCapacity(count)
        for index in 0..<min(count, procs.count) {
            var entry = procs[index]
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard !name.isEmpty else { continue }
            out.append((pid: pid, name: name))
        }
        return out
    }

    /// Footprint and cumulative CPU for one pid, in a single call. nil when the
    /// kernel refuses (root-owned processes).
    static func processUsage(_ pid: Int32) -> (footprint: Int64, cpuTicks: UInt64)? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            let reinterpreted = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V6, reinterpreted)
        }
        guard result == 0 else { return nil }
        return (Int64(info.ri_phys_footprint), info.ri_user_time &+ info.ri_system_time)
    }

    /// A process's physical footprint in bytes: the number Activity Monitor
    /// shows in its "Memory" column. nil when the kernel refuses (root-owned
    /// processes).
    ///
    /// CALLING CONVENTION, because both natural spellings crash: the C signature
    /// is `int proc_pid_rusage(int, int, rusage_info_t *)` where `rusage_info_t`
    /// is itself `void *`, so the parameter is nominally `void **` - but real C
    /// callers pass `(rusage_info_t *)&struct` and the kernel writes the STRUCT
    /// at that address. There is no second indirection.
    ///
    /// So the pointer must be REINTERPRETED, not rebound.
    /// `withMemoryRebound(to: rusage_info_t?.self)` traps at runtime, because
    /// Swift checks that 464 bytes (`rusage_info_v6`) and 8 bytes (a pointer)
    /// are layout-compatible and they are not. Allocating a raw buffer and
    /// passing a pointer to it fails the same way. `assumingMemoryBound`
    /// performs exactly the cast C performs. Getting this wrong is an
    /// `Abort trap: 6`, not a wrong number, so it fails loudly.
    static func footprintBytes(_ pid: Int32) -> Int64? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            let reinterpreted = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V6, reinterpreted)
        }
        guard result == 0 else { return nil }
        return Int64(info.ri_phys_footprint)
    }

    /// Highest `metric` first. Split out so both rankings are one tested path.
    static func top(
        _ processes: [ProcessSample],
        by metric: (ProcessSample) -> Double,
        limit: Int
    ) -> [ProcessSample] {
        processes.sorted { metric($0) > metric($1) }.prefix(limit).map { $0 }
    }

}

/// Observable machine stats for the panel: polls only while something is
/// rendering it, keeps a short CPU history for the sparkline.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var sample = SystemSample()
    /// Newest last, oldest first. Bounded so an all-day panel cannot grow it.
    private(set) var cpuHistory: [Double] = []
    /// Memory utilization history, same cadence and bound as `cpuHistory`.
    /// Kept separate rather than as a tuple series so each card animates on
    /// its own value and neither redraws when only the other moved.
    private(set) var memoryHistory: [Double] = []
    /// False until the first delta-based reading lands, so the card can show a
    /// placeholder instead of a fake 0%.
    private(set) var hasSample = false

    /// Seconds between readings while visible. Fast enough to watch an agent
    /// spin up a build, slow enough that the work is invisible.
    ///
    /// 2 s was the first choice and it was too fast, for a reason that has
    /// nothing to do with sampling: reading the counters costs under 1 ms, but
    /// every tick publishes new values into ~10 observed views and SwiftUI
    /// re-runs the whole panel's layout. `sample` showed Pulse at 29-43% CPU
    /// with the panel open, essentially all of it in `LayoutEngineBox` and
    /// `StackLayout`, not in the sampler. 3 s halves that with no practical
    /// loss of resolution - the numbers are for judging headroom, not for
    /// profiling.
    var interval: TimeInterval = 3

    static let historyLimit = 60

    private let sampler = SystemSampler()
    private var subscribers = 0
    private var loop: Task<Void, Never>?

    /// Ref-counted so several views (both panel layouts, previews) can hold the
    /// monitor alive without one disappearing stopping the others.
    func addSubscriber() {
        subscribers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func removeSubscriber() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    func poll() async {
        let sampleStart = DispatchTime.now().uptimeNanoseconds
        let next = await sampler.sample()
        let sampled = DispatchTime.now().uptimeNanoseconds
        let breakdown = await sampler.lastTimings
        apply(next)
        let applied = DispatchTime.now().uptimeNanoseconds
        if ProcessInfo.processInfo.arguments.contains("--trace-ticks") {
            let sampleMS = Double(sampled - sampleStart) / 1_000_000
            let applyMS = Double(applied - sampled) / 1_000_000
            let line = String(format: "sample=%.2fms apply=%.2fms | %@\n", sampleMS, applyMS, breakdown)
            if let handle = FileHandle(forWritingAtPath: "/tmp/pulse-ticks.log") {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: "/tmp/pulse-ticks.log", atomically: false, encoding: .utf8)
            }
        }
    }

    /// Separated from `poll` so tests can drive the observable state without a
    /// real host reading.
    func apply(_ next: SystemSample) {
        // Publishing an identical sample still invalidates every observed view
        // and re-runs the panel's layout, which is where the CPU actually goes.
        // A machine sitting still therefore costs nothing now.
        guard next != sample || !hasSample else { return }
        sample = next
        hasSample = true
        Self.append(next.cpuTotal, to: &cpuHistory)
        Self.append(next.memoryUtilization, to: &memoryHistory)
    }

    /// Appends and trims in one place, so the two series can never drift out of
    /// step on length or trimming rule.
    private static func append(_ value: Double, to series: inout [Double]) {
        series.append(value)
        if series.count > historyLimit {
            series.removeFirst(series.count - historyLimit)
        }
    }
}
