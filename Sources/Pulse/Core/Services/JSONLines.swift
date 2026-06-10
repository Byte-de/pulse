import Foundation

/// Helpers for JSON-Lines files (Claude project logs, Codex session rollouts).
enum JSONLines {
    /// Iterates non-empty lines of a JSONL file without copying per line.
    /// Files are read whole (they are at most tens of MB) and split lazily.
    static func forEachLine(of url: URL, _ body: (Substring) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let text = String(decoding: data, as: UTF8.self)
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[start..<end]
            if !line.isEmpty, line.contains("{") {
                try body(line)
            }
            start = end < text.endIndex ? text.index(after: end) : text.endIndex
        }
    }

    /// Decodes one JSONL line into `T`, returning nil on mismatch (callers skip
    /// lines that aren't the record type they care about).
    static func decode<T: Decodable>(_ type: T.Type, from line: Substring) -> T? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
