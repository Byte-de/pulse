// Assertions for 429 handling: Retry-After parsing, the rate-limited error
// case, and - the part that actually mattered - the scheduler refusing to call
// a provider that is inside a provider-imposed cooldown, including when the
// limits half of a fetch failed while the rest succeeded.
//
// Compiled against the real sources by scripts/verify-rate-limit-backoff.sh,
// which also plants known defects and requires each to break at least one
// check here. Prints "ALL PASS" only when everything holds.

import AppKit
import Foundation
import Network

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

// ---------------------------------------------------------------- Retry-After

func response(_ headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        statusCode: 429,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

// The exact value observed from Anthropic's usage endpoint, 2026-08-28.
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": "2808"])),
    2808,
    "Retry-After delta-seconds"
)
checkEqual(
    HTTPClient.retryAfter(from: response(["retry-after": "60"])),
    60,
    "Retry-After header lookup is case-insensitive"
)
checkEqual(
    HTTPClient.retryAfter(from: response([:])),
    nil,
    "absent Retry-After is nil, not zero"
)
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": "0"])),
    nil,
    "zero Retry-After is treated as absent"
)
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": "-5"])),
    nil,
    "negative Retry-After is treated as absent"
)
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": "not-a-date"])),
    nil,
    "unparseable Retry-After is nil"
)
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": "999999"])),
    24 * 3600,
    "absurd Retry-After is clamped to 24h"
)

// HTTP-date form. Built here rather than hardcoded so the check does not rot.
let inTwoMinutes = Date().addingTimeInterval(120)
let imf = DateFormatter()
imf.locale = Locale(identifier: "en_US_POSIX")
imf.timeZone = TimeZone(identifier: "GMT")
imf.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
if let parsed = HTTPClient.retryAfter(from: response(["Retry-After": imf.string(from: inTwoMinutes)])) {
    check(abs(parsed - 120) <= 2, "Retry-After HTTP-date form: got \(parsed), expected ~120")
} else {
    failures.append("Retry-After HTTP-date form returned nil")
}
// A date already in the past must not produce a cooldown.
checkEqual(
    HTTPClient.retryAfter(from: response(["Retry-After": imf.string(from: Date().addingTimeInterval(-600))])),
    nil,
    "past HTTP-date Retry-After is nil"
)

// ------------------------------------------------- send() over a real socket

// Parsing the header correctly is worthless if `send` never asks for it. The
// first version of this harness tested `retryAfter(from:)` in isolation and
// PASSED with the call site rewired to `retryAfter: nil` - the exact original
// bug. So the wiring is exercised against a real 429 on a real socket.
final class OneShotServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: String
    private(set) var port: UInt16 = 0

    init(response: String) throws {
        self.response = response
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.port = self.listener.port?.rawValue ?? 0
            ready.signal()
        }
        listener.newConnectionHandler = { [response] connection in
            connection.start(queue: .global())
            // Read the request line, then answer. Content-Length: 0 and an
            // explicit close keep URLSession from waiting for a body.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.start(queue: .global())
        return ready.wait(timeout: .now() + 5) == .success && port != 0
    }

    func stop() { listener.cancel() }
}

func checkSendMapsRateLimit() {
    let body = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 2808\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    guard let server = try? OneShotServer(response: body), server.start() else {
        failures.append("could not start the local 429 server")
        return
    }
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(server.port)/api/oauth/usage")!
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var caught: (any Error)?
    Task {
        do {
            _ = try await HTTPClient().get(url)
        } catch {
            caught = error
        }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    guard let error = caught as? ProviderFetchError else {
        failures.append("a 429 did not surface as a ProviderFetchError (got \(String(describing: caught)))")
        return
    }
    guard case .rateLimited(let retryAfter) = error else {
        failures.append("a 429 must map to .rateLimited, got \(error)")
        return
    }
    checkEqual(
        retryAfter,
        2808,
        "send() must carry the response's Retry-After into the error, not drop it"
    )
}

checkSendMapsRateLimit()

// ---------------------------------------------------------------- error case

let limited = ProviderFetchError.rateLimited(retryAfter: 2808)
check(limited.isTransient, "rateLimited must be transient (it drives backoff)")
checkEqual(limited.retryAfter, 2808, "retryAfter accessor")
// The message names an ABSOLUTE time, because it is frozen into the snapshot's
// status notes for the whole penalty window (see ProviderFetchError). A
// relative "in 46m" would be wrong for 45 of those 46 minutes.
check(
    limited.userMessage.contains(Formatters.clockTime(Date(timeIntervalSinceNow: 2808))),
    "userMessage should name when it will retry, got: \(limited.userMessage)"
)
check(
    !limited.userMessage.contains("46m"),
    "userMessage must not use a relative wait that freezes: \(limited.userMessage)"
)
checkEqual(
    ProviderFetchError.rateLimited(retryAfter: nil).retryAfter,
    nil,
    "retryAfter nil when the provider sent no header"
)
check(
    ProviderFetchError.unauthorized.retryAfter == nil,
    "retryAfter must be nil for non-rate-limit errors"
)

// ---------------------------------------------------------------- scheduler

/// Counts calls, so "did not call again" is observable rather than assumed.
actor CountingProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let descriptor: ProviderDescriptor
    private var snapshotToReturn: UsageSnapshot
    private(set) var fetchCount = 0

    init(id: ProviderID, snapshot: UsageSnapshot) {
        self.id = id
        self.descriptor = ProviderDescriptor(
            id: id,
            name: "Test",
            shortCode: "TST",
            appBundleID: nil,
            webURL: URL(string: "https://example.invalid")!,
            setupHint: "n/a"
        )
        self.snapshotToReturn = snapshot
    }

    func probeConnection() async -> ProviderConnection { .available }

    func fetch() async throws -> UsageSnapshot {
        fetchCount += 1
        return snapshotToReturn
    }

    func setSnapshot(_ snapshot: UsageSnapshot) { snapshotToReturn = snapshot }
}

func makeSnapshot(_ id: ProviderID, limitsError: ProviderFetchError?) -> UsageSnapshot {
    var snapshot = UsageSnapshot(providerID: id)
    // The token half always succeeds - that is precisely the case that hid the
    // failure from the scheduler before this fix.
    snapshot.tokens = TokenUsageReport(
        today: TokenTotals(input: 10),
        thisMonth: TokenTotals(input: 10),
        modelBreakdown: [],
        showsCost: true
    )
    if let limitsError {
        snapshot.limitsUnavailable = true
        snapshot.limitsError = limitsError
    } else {
        snapshot.primary = LimitWindow(
            id: "five_hour",
            title: "5-Hour Session",
            systemImage: "clock",
            utilization: 42
        )
    }
    return snapshot
}

@MainActor
func runSchedulerChecks() async {
    let id = ProviderID.claude
    let defaults = UserDefaults(suiteName: "de.byte.pulse.ratelimit-harness")!
    defaults.removePersistentDomain(forName: "de.byte.pulse.ratelimit-harness")
    let settings = SettingsStore(defaults: defaults)
    settings.enabledProviders = [id]

    // --- 1. a limits-only 429 must arm a cooldown, not read as a clean success
    let provider = CountingProvider(id: id, snapshot: makeSnapshot(id, limitsError: .rateLimited(retryAfter: 2808)))
    let store = UsageStore()
    let scheduler = RefreshScheduler(
        providers: [provider],
        store: store,
        history: HistoryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulse-ratelimit-harness-\(UUID().uuidString)")),
        settings: settings
    )

    scheduler.refreshAll()
    try? await Task.sleep(for: .milliseconds(400))

    let firstCount = await provider.fetchCount
    checkEqual(firstCount, 1, "first refresh should call the provider once")
    check(
        store.record(for: id).snapshot != nil,
        "the token half of a degraded snapshot must still reach the UI"
    )

    guard let remaining = scheduler.cooldownRemaining(id) else {
        failures.append("a limits-only 429 armed no cooldown - the scheduler will keep calling every tick")
        return
    }
    check(
        remaining > 2808 && remaining <= 2808 * 1.1,
        "cooldown should be Retry-After plus a small pad, got \(Int(remaining))s"
    )

    // --- 2. every entry point must respect it, not just the loop
    scheduler.refreshAll()
    try? await Task.sleep(for: .milliseconds(400))
    checkEqual(
        await provider.fetchCount,
        1,
        "refreshAll called the provider again inside its cooldown - this is what renews the 429"
    )

    // The panel's own path (⌘R / opening the panel) is the leak that a
    // loop-only guard would miss.
    scheduler.refreshAll(ifOlderThan: 20)
    try? await Task.sleep(for: .milliseconds(400))
    checkEqual(
        await provider.fetchCount,
        1,
        "opening the panel called the provider again inside its cooldown"
    )

    // --- 3. a clean success clears the cooldown
    let healthy = CountingProvider(id: id, snapshot: makeSnapshot(id, limitsError: nil))
    let store2 = UsageStore()
    let scheduler2 = RefreshScheduler(
        providers: [healthy],
        store: store2,
        history: HistoryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulse-ratelimit-harness-\(UUID().uuidString)")),
        settings: settings
    )
    scheduler2.refreshAll()
    try? await Task.sleep(for: .milliseconds(400))
    checkEqual(scheduler2.cooldownRemaining(id), nil, "a clean fetch must leave no cooldown")
    scheduler2.refreshAll()
    try? await Task.sleep(for: .milliseconds(400))
    checkEqual(
        await healthy.fetchCount,
        2,
        "a healthy provider must still be refreshed normally"
    )

    // --- 4. a 429 with no Retry-After still backs off, without a cooldown
    let vague = CountingProvider(id: id, snapshot: makeSnapshot(id, limitsError: .rateLimited(retryAfter: nil)))
    let scheduler3 = RefreshScheduler(
        providers: [vague],
        store: UsageStore(),
        history: HistoryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulse-ratelimit-harness-\(UUID().uuidString)")),
        settings: settings
    )
    scheduler3.refreshAll()
    try? await Task.sleep(for: .milliseconds(400))
    checkEqual(
        scheduler3.cooldownRemaining(id),
        nil,
        "no Retry-After means no hard cooldown (backoff only) - never an invented wait"
    )

    defaults.removePersistentDomain(forName: "de.byte.pulse.ratelimit-harness")
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await runSchedulerChecks()
    semaphore.signal()
}
// The checks hop through the main actor, so the main thread must keep running
// them rather than blocking on the semaphore.
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

if failures.isEmpty {
    print("ALL PASS")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
