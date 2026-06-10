import Foundation

/// Error taxonomy shared by all providers. Keep cases coarse — the UI maps them
/// to a handful of states (signed out, offline, broken parse) and the scheduler
/// uses them for backoff decisions.
enum ProviderFetchError: Error, Sendable, Equatable {
    /// Credentials missing or rejected; `hint` tells the user how to fix it.
    case notLoggedIn(hint: String)
    /// Transport-level failure (offline, DNS, timeout).
    case network(description: String)
    /// Non-2xx response that is not an auth failure.
    case http(status: Int)
    /// Token present but rejected (401/403).
    case unauthorized
    /// Response or file contents did not match the expected shape.
    case parsing(description: String)
    /// Provider reachable but has no usable data yet (e.g. no session logs).
    case dataUnavailable(description: String)

    /// Short, user-facing message for the error state card / footer.
    var userMessage: String {
        switch self {
        case .notLoggedIn(let hint): hint
        case .network: "Can't reach the network"
        case .http(let status): "Service error (\(status))"
        case .unauthorized: "Session expired — sign in again"
        case .parsing: "Unexpected data from provider"
        case .dataUnavailable(let description): description
        }
    }

    /// Whether retrying soon is likely to help (drives scheduler backoff).
    var isTransient: Bool {
        switch self {
        case .network, .http: true
        case .notLoggedIn, .unauthorized, .parsing, .dataUnavailable: false
        }
    }
}
