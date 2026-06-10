import Foundation

/// Stable identifier for every provider Pulse can track.
///
/// `allCases` order defines the canonical display order (tab bar, menu bar blocks).
enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case claude
    case codex
    case cursor
    case copilot
    case gemini

    var id: String { rawValue }
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
