import Foundation

/// Incremental per-file aggregation with on-disk persistence.
///
/// Both the Claude and Codex parsers walk large JSONL trees every refresh.
/// This cache stores one `Aggregate` per file keyed by (size, mtime), so a
/// refresh only re-parses files that actually changed. The first scan is the
/// only expensive one.
actor FileAggregationCache<Aggregate: Codable & Sendable> {
    private struct Entry: Codable {
        var size: Int64
        var modified: Date
        var aggregate: Aggregate
    }

    private let cacheFile: URL
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(name: String) {
        self.cacheFile = AppPaths.cacheDirectory.appendingPathComponent("\(name).json")
    }

    /// Returns the aggregate for every file, recomputing only changed/new files.
    /// Files that fail to parse are skipped (and retried next refresh).
    /// Entries for files no longer in `files` are dropped from the cache.
    func aggregates(
        for files: [FileSnapshot],
        compute: @Sendable (URL) throws -> Aggregate
    ) -> [Aggregate] {
        loadIfNeeded()

        var fresh: [String: Entry] = [:]
        fresh.reserveCapacity(files.count)
        var changedCount = 0

        for file in files {
            let key = file.url.path
            if let cached = entries[key], cached.size == file.size, cached.modified == file.modified {
                fresh[key] = cached
                continue
            }
            guard let aggregate = try? compute(file.url) else { continue }
            fresh[key] = Entry(size: file.size, modified: file.modified, aggregate: aggregate)
            changedCount += 1
        }

        let removedAny = fresh.count != entries.count
        entries = fresh
        if changedCount > 0 || removedAny {
            persist()
        }
        return entries.values.map(\.aggregate)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
