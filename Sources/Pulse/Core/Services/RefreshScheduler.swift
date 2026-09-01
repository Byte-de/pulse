import AppKit
import Foundation

/// Drives periodic provider refreshes: one loop per enabled provider with
/// jitter, exponential backoff on transient errors, an immediate pass on wake
/// from sleep, and on-demand refreshes when the panel opens.
@MainActor
final class RefreshScheduler {
    private let providers: [any UsageProvider]
    private let store: UsageStore
    private let history: HistoryStore
    private let settings: SettingsStore

    private var loops: [ProviderID: Task<Void, Never>] = [:]
    private var backoffMultiplier: [ProviderID: Double] = [:]
    /// Earliest time a provider may be called again, set from a 429's
    /// `Retry-After`. Exponential backoff alone cannot honour it: the loop caps
    /// at 600 s and Anthropic's usage endpoint asks for 2808 s, so without a
    /// hard floor the app calls back inside the penalty window and renews it.
    private var cooldownUntil: [ProviderID: Date] = [:]

    /// Whether a provider is inside a provider-imposed cooldown right now.
    /// Exposed for the panel's refresh affordance and for verification.
    func cooldownRemaining(_ id: ProviderID, now: Date = .now) -> TimeInterval? {
        guard let until = cooldownUntil[id], until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    init(providers: [any UsageProvider], store: UsageStore, history: HistoryStore, settings: SettingsStore) {
        self.providers = providers
        self.store = store
        self.history = history
        self.settings = settings
    }

    /// The scheduler lives for the app's lifetime, so the wake observer is
    /// intentionally never removed.
    func start() {
        syncLoops()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    /// Reconciles running loops with the enabled-provider set (Settings toggles).
    func syncLoops() {
        let enabled = Set(settings.enabledProviders)
        for (id, task) in loops where !enabled.contains(id) {
            task.cancel()
            loops[id] = nil
        }
        for provider in providers where enabled.contains(provider.id) && loops[provider.id] == nil {
            loops[provider.id] = makeLoop(for: provider)
        }
    }

    /// Immediate refresh of all (or providers older than `ifOlderThan`).
    func refreshAll(ifOlderThan age: TimeInterval = 0) {
        let now = Date.now
        for provider in providers where settings.enabledProviders.contains(provider.id) {
            let last = store.record(for: provider.id).lastSuccess ?? .distantPast
            guard now.timeIntervalSince(last) >= age else { continue }
            Task { await self.refresh(provider) }
        }
        // NOTE: the cooldown is enforced inside `refresh`, not here, so EVERY
        // caller is covered - the loop, this method, the wake observer and the
        // panel's manual ⌘R alike. A guard placed only in the loop is the
        // obvious version of this fix and it leaks: opening the panel calls
        // `refreshAll(ifOlderThan: 20)`, which would walk straight past it.
    }

    private func makeLoop(for provider: any UsageProvider) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(provider)

                let base = self.settings.refreshInterval
                let multiplier = self.backoffMultiplier[provider.id] ?? 1
                let jitter = Double.random(in: 0...3)
                // Sleep past the cooldown rather than waking every interval to
                // be turned away: the guard in `refresh` is what makes this
                // safe, this only stops 47 pointless wake-ups.
                let cooldown = self.cooldownRemaining(provider.id) ?? 0
                let interval = max(min(base * multiplier, 600), cooldown) + jitter
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refresh(_ provider: any UsageProvider) async {
        let id = provider.id
        guard !store.record(for: id).isRefreshing else { return }
        // Inside a provider-imposed cooldown, the most useful request is none.
        guard cooldownRemaining(id) == nil else { return }
        store.setRefreshing(id, true)

        switch await provider.probeConnection() {
        case .notConnected(let hint):
            store.applyNotConnected(id, hint: hint)
            backoffMultiplier[id] = 1
            return
        case .available:
            break
        }

        do {
            let snapshot = try await provider.fetch()
            guard !Task.isCancelled else {
                store.setRefreshing(id, false)
                return
            }
            store.apply(snapshot)
            // A snapshot whose limits half failed is NOT a clean success. It
            // used to reset the backoff here, which is what let a 429'd
            // provider be called every 60 s forever: the token history kept
            // succeeding, so the failure never reached this code.
            if let limitsError = snapshot.limitsError, limitsError.isTransient {
                applyBackoff(id, error: limitsError)
            } else {
                backoffMultiplier[id] = 1
                cooldownUntil[id] = nil
            }
            await recordAndDerive(snapshot)
        } catch is CancellationError {
            // Settings toggled the provider off mid-fetch — not an error.
            store.setRefreshing(id, false)
        } catch let error as ProviderFetchError {
            guard !Task.isCancelled else {
                store.setRefreshing(id, false)
                return
            }
            store.applyError(id, error)
            if error.isTransient {
                applyBackoff(id, error: error)
            }
        } catch {
            store.applyError(id, .parsing(description: error.localizedDescription))
        }
    }

    /// Doubles the loop's interval and, when the provider named a wait, holds a
    /// hard cooldown for at least that long.
    private func applyBackoff(_ id: ProviderID, error: ProviderFetchError) {
        backoffMultiplier[id] = min((backoffMultiplier[id] ?? 1) * 2, 8)
        guard let retryAfter = error.retryAfter else { return }
        // 5% padding: coming back on the exact second the provider named is a
        // coin flip against its own clock, and losing that flip costs another
        // full penalty window.
        let until = Date(timeIntervalSinceNow: retryAfter * 1.05)
        if until > (cooldownUntil[id] ?? .distantPast) {
            cooldownUntil[id] = until
        }
    }

    /// Persists the gauge sample, then recomputes trends + rate series for the UI.
    private func recordAndDerive(_ snapshot: UsageSnapshot) async {
        let id = snapshot.providerID
        await history.record(
            id,
            primary: snapshot.primary?.utilization,
            secondary: snapshot.secondary?.utilization,
            tertiary: snapshot.tertiary?.utilization
        )
        let primaryTrend = await history.delta(id, of: \.primary, over: 3600).map { Trend(delta: $0) }
        let secondaryTrend = await history.delta(id, of: \.secondary, over: 3600).map { Trend(delta: $0) }
        let tertiaryTrend = await history.delta(id, of: \.tertiary, over: 3600).map { Trend(delta: $0) }
        let samples = await history.series(id, since: .now.addingTimeInterval(-5.5 * 3600))
        let rate = UsageMath.rateSeries(samples: samples)
        store.applyDerived(
            id,
            primaryTrend: primaryTrend,
            secondaryTrend: secondaryTrend,
            tertiaryTrend: tertiaryTrend,
            rateSeries: rate
        )
    }
}
