import Foundation
import Observation

/// Per-provider UI state: the last good snapshot plus whatever is currently
/// going wrong, so errors degrade the display (stale badge) instead of
/// blanking it.
struct ProviderRecord: Sendable {
    var snapshot: UsageSnapshot?
    var lastError: ProviderFetchError?
    var notConnectedHint: String?
    var isRefreshing = false
    var lastSuccess: Date?
    var hasLoadedOnce = false
    /// Consecutive not-connected probes. The probe can fail transiently
    /// (SQLite torn read, slow securityd after wake), so one bad probe must
    /// not wipe a good snapshot — see `UsageStore.applyNotConnected`.
    var notConnectedStrikes = 0

    /// Trend arrows (vs ~1h ago), computed by the scheduler from history.
    var primaryTrend: Trend?
    var secondaryTrend: Trend?
    /// Usage-rate series for the chart, recomputed after each sample.
    var rateSeries: [RatePoint] = []

    enum DisplayState: Sendable, Equatable {
        case loading
        case data
        case notConnected(hint: String)
        case error(ProviderFetchError)
    }

    var displayState: DisplayState {
        if snapshot != nil { return .data }
        if let notConnectedHint { return .notConnected(hint: notConnectedHint) }
        if let lastError { return .error(lastError) }
        return .loading
    }

    /// True when the last refresh failed but old data is still on screen.
    var isStale: Bool { snapshot != nil && lastError != nil }

    /// Whether the provider saw any use in the last 7 days (or is mid-window
    /// right now). Drives menu-bar visibility: dormant or unconnected
    /// providers keep their tab but stay out of the bar.
    var isActiveRecently: Bool {
        guard let snapshot else { return false }
        if let primary = snapshot.primary, primary.utilization > 0 { return true }
        return snapshot.dailyUsage.contains { $0.totals.total > 0 }
    }
}

/// Single source of truth the UI observes. All mutation happens on the main
/// actor via the refresh scheduler.
@MainActor
@Observable
final class UsageStore {
    private(set) var records: [ProviderID: ProviderRecord] = [:]

    func record(for id: ProviderID) -> ProviderRecord {
        records[id] ?? ProviderRecord()
    }

    /// Most recent successful update across providers (footer timestamp).
    var lastUpdated: Date? {
        records.values.compactMap(\.lastSuccess).max()
    }

    var isAnyRefreshing: Bool {
        records.values.contains(where: \.isRefreshing)
    }

    func setRefreshing(_ id: ProviderID, _ refreshing: Bool) {
        var record = record(for: id)
        record.isRefreshing = refreshing
        records[id] = record
    }

    func apply(_ snapshot: UsageSnapshot) {
        var record = record(for: snapshot.providerID)
        var incoming = snapshot

        // Limits source blipped but the rest of the snapshot is good: keep the
        // previous gauges on screen rather than blanking the headline cards.
        if incoming.limitsUnavailable, let previous = record.snapshot {
            if incoming.primary == nil { incoming.primary = previous.primary }
            if incoming.secondary == nil { incoming.secondary = previous.secondary }
            if incoming.extraWindows.isEmpty { incoming.extraWindows = previous.extraWindows }
        }

        record.snapshot = incoming
        record.lastError = nil
        record.notConnectedHint = nil
        record.lastSuccess = incoming.fetchedAt
        record.hasLoadedOnce = true
        record.isRefreshing = false
        record.notConnectedStrikes = 0
        records[snapshot.providerID] = record
    }

    func applyError(_ id: ProviderID, _ error: ProviderFetchError) {
        var record = record(for: id)
        record.lastError = error
        record.notConnectedHint = nil
        record.hasLoadedOnce = true
        record.isRefreshing = false
        record.notConnectedStrikes = 0
        records[id] = record
    }

    func applyNotConnected(_ id: ProviderID, hint: String) {
        var record = record(for: id)
        record.notConnectedStrikes += 1
        // A genuinely signed-out provider loses its stale data (the empty
        // state is truthful), but only after a second consecutive probe so a
        // transient probe failure can't wipe a good snapshot.
        if record.notConnectedStrikes >= 2 || record.snapshot == nil {
            record.snapshot = nil
            record.notConnectedHint = hint
            record.lastError = nil
        }
        record.hasLoadedOnce = true
        record.isRefreshing = false
        records[id] = record
    }

    func applyDerived(_ id: ProviderID, primaryTrend: Trend?, secondaryTrend: Trend?, rateSeries: [RatePoint]) {
        var record = record(for: id)
        record.primaryTrend = primaryTrend
        record.secondaryTrend = secondaryTrend
        record.rateSeries = rateSeries
        records[id] = record
    }
}
