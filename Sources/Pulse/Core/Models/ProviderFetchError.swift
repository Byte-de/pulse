import Foundation

/// Error taxonomy shared by all providers. Keep cases coarse — the UI maps them
/// to a handful of states (signed out, offline, broken parse) and the scheduler
/// uses them for backoff decisions.
enum ProviderFetchError: Error, Sendable, Equatable {
    /// Credentials missing or rejected; `hint` tells the user how to fix it.
    case notLoggedIn(hint: String)
    /// Transport-level failure (offline, DNS, timeout).
    case network(description: String)
    /// Non-2xx response that is not an auth failure or a rate limit.
    case http(status: Int)
    /// 429. Carries the provider's `Retry-After` when it sent one, in seconds.
    ///
    /// Separate from `.http(429)` because the number changes what the caller
    /// must DO, not just what it says: a provider that answers "come back in
    /// 47 minutes" and is asked again 60 seconds later renews its own penalty,
    /// so this case exists to make the wait un-ignorable at the type level.
    /// Observed on Anthropic's `oauth/usage` endpoint 2026-08-28 and again
    /// 2026-09-01: `Retry-After: 2808`.
    case rateLimited(retryAfter: TimeInterval?)
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
        // An ABSOLUTE time, not "in 46m". This message is captured into the
        // snapshot's status notes at fetch time and then not refreshed until
        // the next fetch - which, by construction, is 46 minutes away. A
        // relative phrasing would sit there reading "retrying in 46m" for the
        // entire 46 minutes and be wrong for all but the first second of it.
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                "Rate limited by the provider — retrying at "
                    + Formatters.clockTime(Date(timeIntervalSinceNow: retryAfter))
            } else {
                "Rate limited by the provider — retrying later"
            }
        case .http(429): "Rate limited by the provider — retrying later"
        case .http(let status) where status >= 500: "Provider is having trouble (\(status))"
        case .http(let status): "Service error (\(status))"
        case .unauthorized: "Session expired — sign in again"
        case .parsing: "Unexpected data from provider"
        case .dataUnavailable(let description): description
        }
    }

    /// Whether retrying soon is likely to help (drives scheduler backoff).
    var isTransient: Bool {
        switch self {
        case .network, .http, .rateLimited: true
        case .notLoggedIn, .unauthorized, .parsing, .dataUnavailable: false
        }
    }

    /// How long the provider asked us to wait, when it said so.
    ///
    /// The scheduler treats this as a hard floor rather than a hint: exponential
    /// backoff caps at 600 s, which is a fifth of the 2808 s Anthropic actually
    /// asks for, so "back off" alone would still call inside the penalty window
    /// and keep renewing it.
    var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }
}
