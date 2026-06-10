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
    }

    private func makeLoop(for provider: any UsageProvider) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(provider)

                let base = self.settings.refreshInterval
                let multiplier = self.backoffMultiplier[provider.id] ?? 1
                let jitter = Double.random(in: 0...3)
                let interval = min(base * multiplier, 600) + jitter
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refresh(_ provider: any UsageProvider) async {
        let id = provider.id
        guard !store.record(for: id).isRefreshing else { return }
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
            backoffMultiplier[id] = 1
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
                backoffMultiplier[id] = min((backoffMultiplier[id] ?? 1) * 2, 8)
            }
        } catch {
            store.applyError(id, .parsing(description: error.localizedDescription))
        }
    }

    /// Persists the gauge sample, then recomputes trends + rate series for the UI.
    private func recordAndDerive(_ snapshot: UsageSnapshot) async {
        let id = snapshot.providerID
        await history.record(
            id,
            primary: snapshot.primary?.utilization,
            secondary: snapshot.secondary?.utilization
        )
        let primaryTrend = await history.delta(id, of: \.primary, over: 3600).map { Trend(delta: $0) }
        let secondaryTrend = await history.delta(id, of: \.secondary, over: 3600).map { Trend(delta: $0) }
        let samples = await history.series(id, since: .now.addingTimeInterval(-5.5 * 3600))
        let rate = UsageMath.rateSeries(samples: samples)
        store.applyDerived(id, primaryTrend: primaryTrend, secondaryTrend: secondaryTrend, rateSeries: rate)
    }
}
