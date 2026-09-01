import Foundation

/// Stable identifier for every provider Pulse can track.
///
/// A **struct, not an enum**, because the set is not known at compile time:
/// Claude Code supports any number of accounts via `CLAUDE_CONFIG_DIR`, each a
/// `~/.claude*` directory discovered at launch. Dot-shorthand (`.claude`,
/// `.codex`) still works through the static members, so call sites read the
/// same as they did under the enum, but `allCases` is now a runtime registry
/// rather than a fixed list.
///
/// The trade-off this makes deliberately: `switch` over a `ProviderID` can no
/// longer be exhaustive, so every such site needs a default. That is the price
/// of not having to edit an enum to see a newly created account.
struct ProviderID: RawRepresentable, Codable, Sendable, Hashable, Identifiable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    // MARK: - Built-in providers

    /// The default Claude Code account (`~/.claude`).
    static let claude = ProviderID(rawValue: "claude")
    static let codex = ProviderID(rawValue: "codex")
    static let cursor = ProviderID(rawValue: "cursor")
    static let copilot = ProviderID(rawValue: "copilot")
    static let gemini = ProviderID(rawValue: "gemini")

    /// Providers that always exist, in canonical display order. Discovered
    /// Claude accounts are spliced in after `.claude` by the registry.
    static let builtIns: [ProviderID] = [.claude, .codex, .cursor, .copilot, .gemini]

    /// Every provider currently known, in display order. Backed by
    /// `ProviderRegistry`, which is populated once at launch.
    static var allCases: [ProviderID] { ProviderRegistry.shared.all }

    /// Whether this id denotes a Claude Code account (the primary or a
    /// discovered `~/.claude-*` profile).
    var isClaudeAccount: Bool {
        self == .claude || rawValue.hasPrefix(Self.claudeAccountPrefix)
    }

    /// Prefix marking a discovered secondary Claude account, e.g.
    /// `claudeAccount.elara` for `~/.claude-elara`. Namespaced so a profile
    /// named "codex" can never collide with the Codex provider.
    static let claudeAccountPrefix = "claudeAccount."

    /// Id for a secondary Claude account discovered at `~/.claude-<suffix>`.
    static func claudeAccount(suffix: String) -> ProviderID {
        ProviderID(rawValue: "\(claudeAccountPrefix)\(suffix)")
    }

    static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The set of providers this launch knows about.
///
/// Claude accounts are discovered from the filesystem, so the list cannot be a
/// compile-time constant. Discovery runs **once**, at launch, and the result is
/// then immutable: a provider appearing or vanishing mid-session would
/// invalidate the refresh loops, the persisted tab selection and the menu bar
/// layout all at once, for no benefit over picking it up next launch.
final class ProviderRegistry: @unchecked Sendable {
    static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var storage: [ProviderID] = ProviderID.builtIns

    private init() {}

    var all: [ProviderID] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Splices discovered Claude accounts in immediately after `.claude`, so
    /// the account tabs sit together and ahead of the other providers.
    /// Idempotent: calling it twice with the same accounts is a no-op.
    func register(claudeAccounts: [ProviderID]) {
        lock.lock()
        defer { lock.unlock() }
        var ordered: [ProviderID] = []
        for builtIn in ProviderID.builtIns {
            ordered.append(builtIn)
            if builtIn == .claude {
                ordered.append(contentsOf: claudeAccounts.filter { $0 != .claude })
            }
        }
        storage = ordered
    }
}

/// Static, UI-facing metadata about a provider. Lives next to each provider
/// implementation; the registry exposes it even when a provider has no data yet.
struct ProviderDescriptor: Sendable {
    let id: ProviderID
    /// Display name, e.g. "Claude".
    let name: String
    /// Three-letter code shown in the menu bar (split 2+1 across two rows).
    let shortCode: String
    /// Bundle id of the provider's desktop app, used by "Open <Provider>".
    let appBundleID: String?
    /// Web fallback when the desktop app is not installed.
    let webURL: URL
    /// Hint rendered in the not-connected empty state.
    let setupHint: String

    var openLabel: String { "Open \(name)" }
}
