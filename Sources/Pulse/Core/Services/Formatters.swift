import Foundation

/// All user-facing number/date formatting, centralized so the UI stays
/// consistent with the reference design ("184.3k", "2.8M", "$4.82",
/// "2h 46m", "4 days 5h 59m", "30s ago").
enum Formatters {
    // MARK: - Tokens

    static func tokenCount(_ value: Int64) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case ..<1000:
            return String(value)
        case ..<1_000_000:
            return trimmed(Double(value) / 1000) + "k"
        default:
            return trimmed(Double(value) / 1_000_000) + "M"
        }
    }

    /// One decimal, dropping ".0" (812.5k but 813k → "813k", 2.8M).
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Money

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    // MARK: - Bytes

    /// "12.4 GB", "870 MB" — base-1000 like the rest of macOS (Finder, Activity
    /// Monitor), NOT base-1024, so Pulse never disagrees with the numbers the
    /// user can check against.
    static func bytes(_ value: Int64) -> String {
        let magnitude = Double(abs(value))
        switch magnitude {
        case ..<1000:
            return "\(value) B"
        case ..<1_000_000:
            return trimmed(magnitude / 1000) + " KB"
        case ..<1_000_000_000:
            return trimmed(magnitude / 1_000_000) + " MB"
        case ..<1_000_000_000_000:
            return trimmed(magnitude / 1_000_000_000) + " GB"
        default:
            return trimmed(magnitude / 1_000_000_000_000) + " TB"
        }
    }

    /// "1.6G", "310M" - unit-suffixed with no space, for narrow table columns
    /// where "1.6 GB" would push the row into truncating the name beside it.
    static func compactBytes(_ value: Int64) -> String {
        let magnitude = Double(abs(value))
        switch magnitude {
        case ..<1000:
            return "\(value)B"
        case ..<1_000_000:
            return trimmed(magnitude / 1000) + "K"
        case ..<1_000_000_000:
            return String(Int((magnitude / 1_000_000).rounded())) + "M"
        default:
            return trimmed(magnitude / 1_000_000_000) + "G"
        }
    }

    // MARK: - Percent

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Magnitude for trend deltas; direction is conveyed by the arrow glyph.
    static func deltaPercent(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude < 1, magnitude >= 0.05 {
            return String(format: "%.1f%%", magnitude)
        }
        return "\(Int(magnitude.rounded()))%"
    }

    // MARK: - Durations & dates

    /// "2h 46m", "4 days 5h 59m", "23m", "<1m" — the two largest units only.
    static func countdown(to date: Date, now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval >= 60 else { return "<1m" }

        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            let dayLabel = days == 1 ? "1 day" : "\(days) days"
            return "\(dayLabel) \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// "11:44 PM" in the user's locale.
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "30s ago", "5m ago", "2h ago" for the footer.
    static func relativeAge(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }

    /// Weekday letters under the daily bars ("Thu", "Fri", ...).
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// Provider model-id → compact display name ("claude-opus-4-8" → "opus-4.8").
enum ModelNames {
    /// Anthropic ids are "claude-<family>-<major>-<minor>"; other providers
    /// (Cursor) use "claude-4.5-opus"-style ids where stripping the prefix
    /// would mangle the name, so the prefix only drops before a known family.
    private static let claudeFamilies = ["opus", "sonnet", "haiku", "fable"]

    static func display(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("claude-") {
            let rest = String(name.dropFirst("claude-".count))
            if claudeFamilies.contains(where: rest.hasPrefix) {
                name = rest
            }
        }
        // Strip dated suffixes like -20251001.
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        // Join trailing version digits with a dot: opus-4-8 → opus-4.8.
        if let range = name.range(of: #"-(\d+)-(\d+)$"#, options: .regularExpression) {
            let version = name[range].dropFirst().replacingOccurrences(of: "-", with: ".")
            name.replaceSubrange(range, with: "-\(version)")
        }
        return name
    }

    /// Attribution bucket for a session whose model jcode never resolved.
    static let unknown = "unknown"

    /// jcode records the model on the session, and decorates it with a routing
    /// suffix the pricing table does not know: `claude-opus-5[1m]` is the same
    /// model as `claude-opus-5`, requested with a 1M context window. The
    /// bracketed part is stripped so both bill and group as one model. A
    /// session jcode never resolved is reported as `unknown` rather than
    /// dropped, so the token totals stay honest even when attribution can't be.
    static func normalizedJcodeModel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknown }
        guard let bracket = raw.firstIndex(of: "[") else { return raw }
        let base = String(raw[raw.startIndex..<bracket])
        return base.isEmpty ? raw : base
    }
}
