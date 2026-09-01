import Foundation

/// Which on-disk session logs count toward tokens and cost.
///
/// An account's usage can come from three kinds of writer, and they are not
/// interchangeable:
///
/// - **the provider's own CLI** — `~/.claude/projects`, `~/.codex/sessions`;
/// - **jcode**, a harness billing the same accounts (`~/.jcode/sessions`);
/// - **pi**, another harness billing the same accounts (`~/.pi/agent/sessions`).
///
/// They are separately switchable because the question "what did *this* tool
/// cost me" is a real one, and because a harness the user has stopped using
/// still has a year of logs on disk inflating every total. Turning one off
/// removes it from the token card, the daily chart and the breakdown together —
/// a source that vanished from one surface but not another would be worse than
/// no switch at all. Limits and quotas are untouched: they come from the
/// provider's API and are a property of the account, not of who spent it.
struct UsageSourceSelection: Sendable, Equatable {
    /// The provider CLI's own logs.
    var providerLogs: Bool
    var jcode: Bool
    var pi: Bool

    // Spelled out because the `init(stored:)` below suppresses the memberwise one.
    init(providerLogs: Bool, jcode: Bool, pi: Bool) {
        self.providerLogs = providerLogs
        self.jcode = jcode
        self.pi = pi
    }

    static let all = UsageSourceSelection(providerLogs: true, jcode: true, pi: true)
    static let none = UsageSourceSelection(providerLogs: false, jcode: false, pi: false)

    /// One switch, addressable so a menu can render the three without
    /// hard-coding each one's binding.
    enum Source: String, CaseIterable, Sendable, Identifiable {
        case providerLogs
        case jcode
        case pi

        var id: String { rawValue }

        /// Menu label. "Provider sessions" rather than a CLI name because the
        /// same row means Claude Code on one tab and Codex on another.
        var label: String {
            switch self {
            case .providerLogs: "Provider sessions"
            case .jcode: "jcode"
            case .pi: "pi"
            }
        }

        /// Short form for the collapsed menu label, where three long names do
        /// not fit in a toolbar.
        var shortLabel: String {
            switch self {
            case .providerLogs: "provider"
            case .jcode: "jcode"
            case .pi: "pi"
            }
        }
    }

    subscript(source: Source) -> Bool {
        get {
            switch source {
            case .providerLogs: providerLogs
            case .jcode: jcode
            case .pi: pi
            }
        }
        set {
            switch source {
            case .providerLogs: providerLogs = newValue
            case .jcode: jcode = newValue
            case .pi: pi = newValue
            }
        }
    }

    var enabled: [Source] { Source.allCases.filter { self[$0] } }

    /// Toolbar label: "All", "None", or the chosen subset.
    var summary: String {
        switch enabled.count {
        case Source.allCases.count: "All"
        case 0: "None"
        default: enabled.map(\.shortLabel).joined(separator: " + ")
        }
    }

    // MARK: - Persistence

    /// Stored as the list of *enabled* raw names. Deliberately not a bitmask:
    /// a new source added later must default to on for an existing user, and an
    /// unknown name from a newer build must be ignored rather than shifting the
    /// meaning of every other bit.
    var storedValue: [String] { enabled.map(\.rawValue) }

    init(stored: [String]?) {
        guard let stored else { self = .all; return }
        let names = Set(stored)
        self = UsageSourceSelection(
            providerLogs: names.contains(Source.providerLogs.rawValue),
            jcode: names.contains(Source.jcode.rawValue),
            pi: names.contains(Source.pi.rawValue)
        )
    }
}

/// Process-wide, lock-guarded copy of `UsageSourceSelection`.
///
/// **Why a gate and not a constructor parameter.** Provider engines are actors
/// created once at launch; `captureTitles` is passed that way and therefore
/// needs a restart to change. That is tolerable for a privacy switch nobody
/// flips twice, and useless for these: the entire point of turning jcode off is
/// to watch the number move. `SettingsStore` is `@MainActor` and lives above
/// Core, so an actor cannot read it directly without inverting the dependency
/// direction (`App → UI → Core ← Providers`). A small Sendable holder that
/// Settings writes and providers read keeps the arrow pointing the right way.
///
/// Reads happen once per provider refresh, not per file, so the lock is never
/// contended.
final class UsageSourceGate: @unchecked Sendable {
    static let shared = UsageSourceGate()

    private let lock = NSLock()
    private var storage: UsageSourceSelection = .all

    private init() {}

    var current: UsageSourceSelection {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
