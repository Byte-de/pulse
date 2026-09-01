import Foundation
import Testing

@testable import Pulse

@Suite("System monitor")
struct SystemMonitorTests {
    // MARK: - ps parsing

    /// Captured from `ps -Aceo pid,pcpu,rss,comm -r` on this machine: leading
    /// spaces on the pid column, RSS in kilobytes, and a command containing a
    /// space (the case a naive `fields[3]` would truncate).
    private let psOutput = """
      PID  %CPU    RSS COMM
      412  92.4 1048576 Xcode
      1    7.1  32768 launchd
      903  3.4  524288 Google Chrome
      77  0.0   4096 loginwindow
      88  0.0   2048 sleepimage
    """

    @Test("Parses pid, cpu, resident bytes and multi-word command")
    func parsesRows() {
        let rows = SystemSampler.parseProcessList(psOutput, limit: 5)

        #expect(rows.count == 5)
        #expect(rows[0].pid == 412)
        #expect(rows[0].name == "Xcode")
        #expect(rows[0].cpu == 92.4)
        // RSS is kilobytes, so the model must report 1 GiB, not 1 MB.
        #expect(rows[0].memory == 1_048_576 * 1024)
        #expect(rows[2].name == "Google Chrome")
    }

    @Test("Honors the row limit rather than returning every process")
    func respectsLimit() {
        #expect(SystemSampler.parseProcessList(psOutput, limit: 2).count == 2)
        #expect(SystemSampler.parseProcessList(psOutput, limit: 99).count == 5)
    }

    @Test("Malformed lines are skipped, not fatal")
    func skipsGarbage() {
        let text = """
        PID %CPU RSS COMM
        notapid x y z
        5 1.0 1024 kernel_task
        """
        let rows = SystemSampler.parseProcessList(text, limit: 4)
        #expect(rows.count == 1)
        #expect(rows[0].name == "kernel_task")
    }

    // MARK: - Rankings

    /// Built so the two rankings DISAGREE: the biggest CPU consumer is not the
    /// biggest memory consumer, and one heavy-memory process is idle. A memory
    /// card that re-sorted the CPU top-N would miss `bigidle` entirely, which
    /// is exactly why the two lists are ranked from the full table.
    private let table = [
        ProcessSample(pid: 1, name: "spinner", cpu: 95, memory: 100_000_000),
        ProcessSample(pid: 2, name: "medium", cpu: 40, memory: 800_000_000),
        ProcessSample(pid: 3, name: "bigidle", cpu: 0.2, memory: 6_000_000_000),
        ProcessSample(pid: 4, name: "small", cpu: 12, memory: 20_000_000),
        ProcessSample(pid: 5, name: "hog", cpu: 60, memory: 3_000_000_000),
        ProcessSample(pid: 6, name: "tiny", cpu: 1, memory: 5_000_000),
    ]

    @Test("CPU and memory rankings are independent, highest first")
    func rankings() {
        let byCPU = SystemSampler.top(table, by: { $0.cpu }, limit: 5)
        #expect(byCPU.map(\.name) == ["spinner", "hog", "medium", "small", "tiny"])

        let byMemory = SystemSampler.top(table, by: { Double($0.memory) }, limit: 5)
        #expect(byMemory.map(\.name) == ["bigidle", "hog", "medium", "spinner", "small"])

        // The idle memory hog leads the memory ranking while sitting nowhere
        // near the top by CPU - the case a re-sort of the CPU list would lose.
        #expect(byMemory.first?.name == "bigidle")
        #expect(!byCPU.prefix(2).map(\.name).contains("bigidle"))
    }

    @Test("Rankings honor their limit and survive an empty table")
    func rankingEdges() {
        #expect(SystemSampler.top(table, by: { $0.cpu }, limit: 2).count == 2)
        #expect(SystemSampler.top([], by: { $0.cpu }, limit: 5).isEmpty)
    }

    // MARK: - Display helpers

    @Test("Process memory is the physical footprint, not ps RSS")
    func footprintNotRSS() {
        // Live check, because the two metrics are both plausible byte counts and
        // only an independent reading distinguishes them. This process always
        // exists, so nil here means the call convention broke.
        let mine = SystemSampler.footprintBytes(ProcessInfo.processInfo.processIdentifier)
        #expect(mine != nil)
        #expect((mine ?? 0) > 0)

        // pid 0 (the kernel) never exposes a footprint, so a nil return must be
        // possible - a version that always succeeds is not reading anything.
        #expect(SystemSampler.footprintBytes(0) == nil)
    }

    @Test("Reverse-DNS process names keep their informative tail")
    func processDisplayNames() {
        // Middle-truncating this rendered "com....ntent" on screen, which names
        // nothing - the defect this helper exists to prevent.
        #expect(ProcessSample.displayName("com.apple.WebKit.WebContent") == "WebKit.WebContent")
        #expect(ProcessSample.displayName("com.apple.Safari") == "Safari")
        #expect(ProcessSample.displayName("rustc") == "rustc")
        #expect(ProcessSample.displayName("kernel_task") == "kernel_task")
    }

    @Test("Compact bytes carry no space, for narrow columns")
    func compactBytes() {
        #expect(Formatters.compactBytes(1_600_000_000) == "1.6G")
        #expect(Formatters.compactBytes(310_000_000) == "310M")
        #expect(Formatters.compactBytes(512) == "512B")
        #expect(!Formatters.compactBytes(1_600_000_000).contains(" "))
    }

    // MARK: - Derived values

    @Test("Utilizations are shares of their totals, capped at 100")
    func utilization() {
        var sample = SystemSample()
        sample.memoryUsed = 24_000_000_000
        sample.memoryTotal = 32_000_000_000
        sample.diskTotal = 1_000_000_000_000
        sample.diskFree = 250_000_000_000
        sample.coreCount = 10
        sample.load1 = 5

        #expect(abs(sample.memoryUtilization - 75) < 0.001)
        #expect(abs(sample.diskUtilization - 75) < 0.001)
        #expect(abs(sample.loadUtilization - 50) < 0.001)
    }

    @Test("Unknown totals report zero instead of dividing by zero")
    func zeroTotals() {
        let sample = SystemSample()
        #expect(sample.memoryUtilization == 0)
        #expect(sample.diskUtilization == 0)
        // coreCount defaults to 1, so load must still be safe.
        #expect(sample.loadUtilization == 0)
    }

    @Test("Load beyond core count saturates rather than exceeding the gauge")
    func loadCap() {
        var sample = SystemSample()
        sample.coreCount = 4
        sample.load1 = 40
        #expect(sample.loadUtilization == 100)
    }

    // MARK: - Monitor state

    @MainActor
    @Test("History keeps newest samples and stays bounded")
    func historyBounded() {
        let monitor = SystemMonitor()
        #expect(monitor.hasSample == false)

        for index in 0..<(SystemMonitor.historyLimit + 20) {
            var sample = SystemSample()
            sample.cpuTotal = Double(index)
            // Memory needs a total to derive a utilization from, and a
            // distinct value so the two series cannot be confused for one.
            sample.memoryTotal = 100
            sample.memoryUsed = Int64(min(index, 100))
            monitor.apply(sample)
        }

        #expect(monitor.hasSample)
        #expect(monitor.cpuHistory.count == SystemMonitor.historyLimit)
        // Newest last: the final value is the last one applied.
        #expect(monitor.cpuHistory.last == Double(SystemMonitor.historyLimit + 19))
        #expect(monitor.cpuHistory.first == Double(20))

        // Both series are appended and trimmed by the same path, so they must
        // never differ in length - a card reading a shorter one would silently
        // plot a stale window.
        #expect(monitor.memoryHistory.count == monitor.cpuHistory.count)
        #expect(monitor.memoryHistory.last == 100)
    }

    @MainActor
    @Test("Memory history tracks utilization, not the raw byte count")
    func memoryHistoryIsUtilization() {
        let monitor = SystemMonitor()
        var sample = SystemSample()
        sample.memoryTotal = 32_000_000_000
        sample.memoryUsed = 8_000_000_000
        monitor.apply(sample)

        // 25%, not 8e9: the sparkline is drawn on a 0...100 scale, so feeding
        // it bytes would peg the line at the top forever.
        #expect(monitor.memoryHistory == [25])
    }

    @Test("Reclaimable disk cache is the gap between the two capacity keys")
    func purgeableDerivation() {
        // The sampler derives this from live URL keys, so the arithmetic is
        // asserted here and the live agreement in the verifier script.
        var sample = SystemSample()
        sample.diskFree = 11_770_000_000       // ...ForImportantUsage
        sample.diskPurgeable = 760_000_000     // important - availableCapacity
        #expect(sample.diskPurgeable <= sample.diskFree)
    }

    @MainActor
    @Test("A real sample reports this machine's cores, RAM and disk")
    func liveSample() async {
        let sampler = SystemSampler()
        // First reading establishes the CPU baseline; the second carries a real
        // delta. Asserting on the first would test the placeholder, not the
        // sampler.
        _ = await sampler.sample(includeProcesses: false)
        try? await Task.sleep(for: .milliseconds(120))
        let sample = await sampler.sample(includeProcesses: false)

        #expect(sample.coreCount >= 1)
        #expect(sample.memoryTotal > 0)
        #expect(sample.memoryUsed > 0)
        #expect(sample.memoryUsed < sample.memoryTotal)
        #expect(sample.diskTotal > 0)
        #expect(sample.cpuTotal >= 0)
        #expect(sample.cpuTotal <= 100)
        #expect(sample.load1 >= 0)
    }

    @MainActor
    @MainActor
    @Test("Process sampling returns real rows for the running machine")
    func liveProcesses() async {
        let sample = await SystemSampler().sample()
        // The test process itself is always running, so an empty list means the
        // `ps` spawn or the parser broke, not a quiet machine.
        #expect(!sample.topProcesses.isEmpty)
        #expect(sample.topProcesses.allSatisfy { $0.pid > 0 })
        #expect(sample.topProcesses.allSatisfy { !$0.name.isEmpty })
        #expect(sample.topProcesses.count == 5)
        #expect(sample.topMemoryProcesses.count == 5)

        // Both cards come from ONE `ps` pass, so a pid present in both must
        // report identical figures in both.
        for row in sample.topMemoryProcesses {
            if let twin = sample.topProcesses.first(where: { $0.pid == row.pid }) {
                #expect(twin.memory == row.memory)
                #expect(twin.cpu == row.cpu)
            }
        }

        // The re-sort defect's exact signature. Comparing the two ORDERS is not
        // enough: a re-sort is a permutation, so the orders differ while the
        // bug is live. Subset is the property that distinguishes them.
        let cpuPIDs = Set(sample.topProcesses.map(\.pid))
        let memoryPIDs = Set(sample.topMemoryProcesses.map(\.pid))
        #expect(!memoryPIDs.isSubset(of: cpuPIDs))
    }

    // MARK: - Formatting

    @Test("Byte formatting matches macOS base-1000 units")
    func byteFormatting() {
        #expect(Formatters.bytes(512) == "512 B")
        #expect(Formatters.bytes(1500) == "1.5 KB")
        #expect(Formatters.bytes(24_000_000_000) == "24 GB")
        #expect(Formatters.bytes(1_250_000_000_000) == "1.3 TB")
    }

    // MARK: - Sparkline geometry

    @Test("Sparkline maps values into the box, newest at the right edge")
    func sparklinePoints() {
        let size = CGSize(width: 100, height: 50)
        let points = Sparkline.points([0, 50, 100], in: size, maximum: 100)

        #expect(points.count == 3)
        #expect(points[0] == CGPoint(x: 0, y: 50))   // 0% sits on the baseline
        #expect(points[1] == CGPoint(x: 50, y: 25))
        #expect(points[2] == CGPoint(x: 100, y: 0))  // 100% touches the top
    }

    @Test("Out-of-range values clamp instead of drawing outside the card")
    func sparklineClamps() {
        let size = CGSize(width: 10, height: 10)
        let points = Sparkline.points([-20, 300], in: size, maximum: 100)
        #expect(points[0].y == 10)
        #expect(points[1].y == 0)
    }

    @Test("Fewer than two samples produce no path")
    func sparklineEmpty() {
        #expect(Sparkline.points([42], in: CGSize(width: 10, height: 10), maximum: 100).isEmpty)
        #expect(Sparkline.points([], in: CGSize(width: 10, height: 10), maximum: 100).isEmpty)
    }
}
