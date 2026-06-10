import Foundation

/// Cursor usage via the local session token (state.vscdb) and the cursor.com
/// dashboard APIs. Endpoints fail independently — any one of them degrading
/// drops its card rather than the whole snapshot; only auth failures abort.
actor CursorProvider: UsageProvider {
    nonisolated let id: ProviderID = .cursor
    nonisolated let descriptor = ProviderDescriptor(
        id: .cursor,
        name: "Cursor",
        shortCode: "CUR",
        appBundleID: "com.todesktop.230313mzl4w4u92",
        webURL: URL(string: "https://cursor.com/dashboard")!,
        setupHint: "Sign in to Cursor to start tracking."
    )

    private let api: CursorAPI
    private let databaseURL: URL

    /// Per-fetch outcome tracking for the six independent endpoints, so a
    /// fully offline fetch fails loudly instead of returning an empty
    /// "success" assembled purely from local state.
    private var remoteSuccesses = 0
    private var firstRemoteError: ProviderFetchError?

    init(http: HTTPClient = HTTPClient(), databaseURL: URL = CursorAuth.defaultDatabaseURL) {
        self.api = CursorAPI(http: http)
        self.databaseURL = databaseURL
    }

    func probeConnection() async -> ProviderConnection {
        CursorAuth.isConnected(databaseURL: databaseURL)
            ? .available
            : .notConnected(hint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        guard let session = CursorAuth.loadSession(databaseURL: databaseURL) else {
            throw ProviderFetchError.notLoggedIn(hint: descriptor.setupHint)
        }

        remoteSuccesses = 0
        firstRemoteError = nil
        let now = Date.now
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        // 30 days feeds the histogram card's month view (shard-safe window).
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now

        // Independent endpoints run concurrently; each degrades to nil on its
        // own failure. 401 means the session token is dead → abort as a whole.
        async let summaryTask = soften { try await self.api.usageSummary(session: session) }
        async let legacyTask = soften { try await self.api.legacyUsage(session: session) }
        async let hardLimitTask = soften { try await self.api.hardLimit(session: session) }
        async let invoiceTask = soften { try await self.api.monthlyInvoice(session: session, now: now) }
        async let aggregatedTask = soften {
            try await self.api.aggregatedUsage(session: session, from: monthStart, to: now)
        }
        async let eventsTask = soften {
            try await self.api.filteredEvents(session: session, from: thirtyDaysAgo, to: now, pageSize: 500)
        }

        let summary = try await summaryTask
        let legacy = try await legacyTask
        let hardLimit = try await hardLimitTask
        let invoice = try await invoiceTask
        let aggregated = try await aggregatedTask
        let events = try await eventsTask

        var snapshot = UsageSnapshot(providerID: .cursor, fetchedAt: now)
        snapshot.plan = CursorAuth.planLabel(session.membershipType ?? summary?.membershipType)
        snapshot.accountLabel = CursorAuth.maskedEmail(session.email)

        snapshot.primary = Self.planWindow(
            summary: summary, legacy: legacy, invoice: invoice, calendar: calendar
        )
        snapshot.secondary = Self.spendWindow(
            summary: summary, hardLimit: hardLimit, invoice: invoice
        )
        snapshot.tokens = Self.tokenReport(aggregated: aggregated, events: events, calendar: calendar, now: now)
        snapshot.dailyUsage = Self.dailyUsage(events: events, calendar: calendar, now: now)
        snapshot.histograms = Self.histograms(events: events, calendar: calendar, now: now)

        // Every remote endpoint failed (offline, total outage): surface the
        // failure so the store keeps the previous snapshot with a stale badge,
        // instead of applying an empty "success" built from local plan info.
        guard remoteSuccesses > 0 else {
            throw firstRemoteError ?? .network(description: "Cursor unreachable")
        }

        snapshot.limitsUnavailable = snapshot.primary == nil
        if snapshot.primary == nil {
            snapshot.statusNotes.append("No plan gauge available for this account")
        }
        return snapshot
    }

    /// nil on any failure except auth (401/403 rethrows so the whole fetch
    /// surfaces a sign-in problem instead of an empty panel). Cancellation
    /// propagates untouched. Outcomes feed the all-remote-failed check above.
    private func soften<T: Sendable>(_ work: @Sendable () async throws -> T?) async throws -> T? {
        do {
            let value = try await work()
            remoteSuccesses += 1
            return value
        } catch ProviderFetchError.unauthorized {
            throw ProviderFetchError.notLoggedIn(hint: "Cursor session expired — open Cursor and sign in.")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderFetchError {
            if firstRemoteError == nil { firstRemoteError = error }
            return nil
        } catch {
            if firstRemoteError == nil {
                firstRemoteError = .network(description: error.localizedDescription)
            }
            return nil
        }
    }

    // MARK: - Snapshot assembly (pure, tested)

    static func planWindow(
        summary: CursorUsageSummary?,
        legacy: CursorLegacyUsage?,
        invoice: CursorMonthlyInvoice?,
        calendar: Calendar
    ) -> LimitWindow? {
        var utilization: Double?
        var detail: String?

        if let percent = summary?.planPercentUsed {
            utilization = percent
            if let used = summary?.individualUsage?.plan?.used?.value,
               let limit = summary?.individualUsage?.plan?.limit?.value, limit > 0 {
                detail = "\(Formatters.money(used / 100)) of \(Formatters.money(limit / 100))"
            }
        } else if let gauge = legacy?.gpt4, let max = gauge.maxRequestUsage, max > 0 {
            let used = gauge.numRequests ?? gauge.numRequestsTotal ?? 0
            utilization = Double(used) / Double(max) * 100
            detail = "\(used) of \(max) requests"
        }
        guard let utilization else { return nil }

        let periodStart = invoice?.periodStart
            ?? CursorDates.iso(summary?.billingCycleStart)
            ?? CursorDates.iso(legacy?.startOfMonth)
        let periodEnd = invoice?.periodEnd
            ?? CursorDates.iso(summary?.billingCycleEnd)
            ?? periodStart.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }

        return LimitWindow(
            id: "plan",
            title: "Plan Usage",
            systemImage: "calendar",
            utilization: utilization,
            resetsAt: periodEnd,
            periodStart: periodStart,
            detail: detail
        )
    }

    static func spendWindow(
        summary: CursorUsageSummary?,
        hardLimit: CursorHardLimit?,
        invoice: CursorMonthlyInvoice?
    ) -> LimitWindow? {
        let limitDollars = hardLimit?.hardLimit?.value
            ?? (summary?.individualUsage?.onDemand?.limit?.value).map { $0 / 100 }
        guard let limitDollars, limitDollars > 0 else { return nil }

        let spendDollars = (invoice?.usageItemCentsTotal).map { $0 / 100 }
            ?? (summary?.individualUsage?.onDemand?.used?.value).map { $0 / 100 }
        guard let spendDollars else { return nil }

        return LimitWindow(
            id: "ondemand",
            title: "On-Demand Spend",
            systemImage: "dollarsign.circle",
            utilization: spendDollars / limitDollars * 100,
            resetsAt: invoice?.periodEnd,
            periodStart: invoice?.periodStart,
            detail: "\(Formatters.money(spendDollars)) of \(Formatters.money(limitDollars))"
        )
    }

    static func tokenReport(
        aggregated: CursorAggregatedUsage?,
        events: CursorFilteredEvents?,
        calendar: Calendar,
        now: Date
    ) -> TokenUsageReport? {
        var month = TokenTotals()
        var perModel: [String: TokenTotals] = [:]

        for aggregation in aggregated?.aggregations ?? [] {
            var totals = TokenTotals(
                input: aggregation.inputTokens?.value ?? 0,
                output: aggregation.outputTokens?.value ?? 0,
                cacheRead: aggregation.cacheReadTokens?.value ?? 0,
                cacheWrite: aggregation.cacheWriteTokens?.value ?? 0
            )
            totals.costUSD = (aggregation.totalCents?.value).map { $0 / 100 }
            month.add(totals)
            perModel[aggregation.modelIntent ?? "unknown", default: .zero].add(totals)
        }

        var today = TokenTotals()
        for event in events?.usageEventsDisplay ?? [] {
            guard let date = event.date, calendar.isDate(date, inSameDayAs: now) else { continue }
            today.add(Self.totals(of: event))
        }

        guard month.total > 0 || today.total > 0 else { return nil }

        let monthTotal = max(month.total, 1)
        let breakdown = perModel
            .map { model, totals in
                ModelShare(
                    model: ModelNames.display(model),
                    share: Double(totals.total) / Double(monthTotal) * 100,
                    totals: totals
                )
            }
            .sorted { $0.share > $1.share }

        return TokenUsageReport(today: today, thisMonth: month, modelBreakdown: breakdown, showsCost: true)
    }

    static func dailyUsage(
        events: CursorFilteredEvents?,
        calendar: Calendar,
        now: Date
    ) -> [DailyUsage] {
        guard let list = events?.usageEventsDisplay, !list.isEmpty else { return [] }
        var perDay: [Date: TokenTotals] = [:]
        for event in list {
            guard let date = event.date else { continue }
            perDay[calendar.startOfDay(for: date), default: .zero].add(Self.totals(of: event))
        }
        return UsageMath.lastSevenDays(from: perDay, calendar: calendar, now: now)
    }

    /// Events carry full timestamps over a 30-day window → hourly today,
    /// 7-day, and 30-day frames. A year of per-event history would need
    /// month-by-month backfill, so `.year` is deliberately unsupported.
    static func histograms(
        events: CursorFilteredEvents?,
        calendar: Calendar,
        now: Date
    ) -> [UsageTimeframe: [DailyUsage]] {
        guard let list = events?.usageEventsDisplay, !list.isEmpty else { return [:] }
        var perDay: [Date: TokenTotals] = [:]
        var perHourToday: [Date: TokenTotals] = [:]
        for event in list {
            guard let date = event.date else { continue }
            let totals = Self.totals(of: event)
            perDay[calendar.startOfDay(for: date), default: .zero].add(totals)
            if calendar.isDate(date, inSameDayAs: now) {
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                if let bucket = calendar.date(from: components) {
                    perHourToday[bucket, default: .zero].add(totals)
                }
            }
        }
        return [
            .day: UsageMath.hoursOfToday(from: perHourToday, calendar: calendar, now: now),
            .week: UsageMath.lastDays(7, from: perDay, calendar: calendar, now: now),
            .month: UsageMath.lastDays(30, from: perDay, calendar: calendar, now: now),
        ]
    }

    private static func totals(of event: CursorFilteredEvents.Event) -> TokenTotals {
        var totals = TokenTotals(
            input: event.tokenUsage?.inputTokens?.value ?? 0,
            output: event.tokenUsage?.outputTokens?.value ?? 0,
            cacheRead: event.tokenUsage?.cacheReadTokens?.value ?? 0,
            cacheWrite: event.tokenUsage?.cacheWriteTokens?.value ?? 0
        )
        totals.costUSD = (event.tokenUsage?.totalCents?.value ?? event.chargedCents?.value).map { $0 / 100 }
        return totals
    }
}
