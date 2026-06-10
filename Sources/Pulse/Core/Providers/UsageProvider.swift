import Foundation

/// Result of the cheap local availability probe (file existence, no network).
enum ProviderConnection: Sendable, Equatable {
    case available
    case notConnected(hint: String)
}

/// Contract every provider engine implements.
///
/// Providers are `Sendable` (typically actors) because the refresh scheduler
/// drives them from concurrent tasks. They must be read-only with respect to
/// the user's CLI state: never write back credentials, never rotate tokens on
/// disk. In-memory token refresh is allowed where the provider requires it.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var descriptor: ProviderDescriptor { get }

    /// Cheap, local-only check whether this provider is set up at all
    /// (credentials file / keychain item present). Called every refresh tick
    /// before `fetch()` so newly signed-in CLIs are picked up automatically.
    func probeConnection() async -> ProviderConnection

    /// Full fetch. Only called when `probeConnection()` returned `.available`.
    /// Throws `ProviderFetchError`; any other error is mapped to `.parsing`.
    func fetch() async throws -> UsageSnapshot
}
