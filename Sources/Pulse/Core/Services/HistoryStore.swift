import Foundation

/// One observation of a provider's gauge values, persisted for trends and the
/// usage-rate chart.
struct UsageSample: Sendable, Equatable, Codable {
    var date: Date
    var primary: Double?
    var secondary: Double?
}

/// Append-only utilization history, one JSONL file per provider under
/// Application Support. Keeps `retention` (14 days) of samples; the rate chart
/// needs 5h and the trend arrows need ~1h, so this is comfortable headroom.
actor HistoryStore {
    private let directory: URL
    private let retention: TimeInterval
    private var samples: [ProviderID: [UsageSample]] = [:]
    private var loaded: Set<ProviderID> = []
    private var lastPrune = Date.distantPast

    init(directory: URL = AppPaths.historyDirectory, retention: TimeInterval = 14 * 24 * 3600) {
        self.directory = directory
        self.retention = retention
    }

    /// Records a sample. Consecutive samples closer than 30s apart are dropped
    /// so a manual refresh storm doesn't distort the rate series.
    func record(_ id: ProviderID, primary: Double?, secondary: Double?, at date: Date = .now) {
        guard primary != nil || secondary != nil else { return }
        loadIfNeeded(id)
        if let last = samples[id]?.last, date.timeIntervalSince(last.date) < 30 { return }

        let sample = UsageSample(date: date, primary: primary, secondary: secondary)
        samples[id, default: []].append(sample)
        append(sample, to: fileURL(id))
        pruneIfDue(now: date)
    }

    /// All samples for a provider since `since`, ascending by date.
    func series(_ id: ProviderID, since: Date) -> [UsageSample] {
        loadIfNeeded(id)
        return (samples[id] ?? []).filter { $0.date >= since }
    }

    /// Percentage-point change of a gauge vs the sample closest to `interval`
    /// ago. Returns nil when history doesn't reach far enough back (with 50%
    /// slack) so young installs don't show meaningless arrows.
    func delta(
        _ id: ProviderID,
        of keyPath: KeyPath<UsageSample, Double?> & Sendable,
        over interval: TimeInterval,
        now: Date = .now
    ) -> Double? {
        loadIfNeeded(id)
        guard let all = samples[id], let current = all.last?[keyPath: keyPath] else { return nil }

        let target = now.addingTimeInterval(-interval)
        let candidates = all.filter { abs($0.date.timeIntervalSince(target)) <= interval * 0.5 }
        guard let reference = candidates.min(by: {
            abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
        }), let referenceValue = reference[keyPath: keyPath] else { return nil }

        return current - referenceValue
    }

    // MARK: - Persistence

    private func fileURL(_ id: ProviderID) -> URL {
        directory.appendingPathComponent("history-\(id.rawValue).jsonl")
    }

    private func loadIfNeeded(_ id: ProviderID) {
        guard !loaded.contains(id) else { return }
        loaded.insert(id)
        let cutoff = Date.now.addingTimeInterval(-retention)
        var result: [UsageSample] = []
        try? JSONLines.forEachLine(of: fileURL(id)) { line in
            if let sample = JSONLines.decode(UsageSample.self, from: line), sample.date >= cutoff {
                result.append(sample)
            }
        }
        samples[id] = result.sorted { $0.date < $1.date }
    }

    private func append(_ sample: UsageSample, to url: URL) {
        guard var data = try? JSONEncoder().encode(sample) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Rewrites files at most daily, dropping samples past retention.
    private func pruneIfDue(now: Date) {
        guard now.timeIntervalSince(lastPrune) > 24 * 3600 else { return }
        lastPrune = now
        let cutoff = now.addingTimeInterval(-retention)
        for id in loaded {
            let kept = (samples[id] ?? []).filter { $0.date >= cutoff }
            guard kept.count != samples[id]?.count else { continue }
            samples[id] = kept
            let encoder = JSONEncoder()
            let lines = kept.compactMap { try? encoder.encode($0) }
            var blob = Data()
            for line in lines {
                blob.append(line)
                blob.append(0x0A)
            }
            try? blob.write(to: fileURL(id), options: .atomic)
        }
    }
}
