import Foundation

/// Central place for filesystem locations Pulse owns, plus the home-relative
/// provider paths it reads. Everything outside `appSupport` is read-only.
enum AppPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/Pulse — created on first access.
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cacheDirectory: URL {
        let dir = appSupport.appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var historyDirectory: URL {
        let dir = appSupport.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Identity + change detection for a file feeding an incremental aggregation.
struct FileSnapshot: Sendable, Equatable {
    let url: URL
    let size: Int64
    let modified: Date

    /// Enumerates files under `root` (recursively) matching `pathExtension`,
    /// optionally keeping only files modified at/after `modifiedSince`.
    static func enumerate(root: URL, pathExtension: String, modifiedSince: Date? = nil) -> [FileSnapshot] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [FileSnapshot] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == pathExtension else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            if let modifiedSince, modified < modifiedSince { continue }
            result.append(FileSnapshot(url: url, size: Int64(size), modified: modified))
        }
        return result
    }
}
