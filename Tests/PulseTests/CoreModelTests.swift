import AppKit
import Foundation
import Testing
@testable import Pulse

@Suite("Pace")
struct PaceTests {
    @Test func criticalAboveNinetyFiveRegardlessOfElapsed() {
        #expect(Pace.evaluate(utilization: 96, elapsedFraction: 0.99) == .critical)
        #expect(Pace.evaluate(utilization: 96, elapsedFraction: nil) == .critical)
    }

    @Test func safeWhenBehindExpectedPace() {
        // 42% used at 45% elapsed → ratio < 1.
        #expect(Pace.evaluate(utilization: 42, elapsedFraction: 0.45) == .safe)
    }

    @Test func elevatedWhenModeratelyAhead() {
        // 30% used at 25% elapsed → ratio 1.2.
        #expect(Pace.evaluate(utilization: 30, elapsedFraction: 0.25) == .elevated)
    }

    @Test func criticalWhenFarAhead() {
        // 40% used at 20% elapsed → ratio 2.
        #expect(Pace.evaluate(utilization: 40, elapsedFraction: 0.20) == .critical)
    }

    @Test func earlyWindowUsesAbsoluteUtilization() {
        #expect(Pace.evaluate(utilization: 10, elapsedFraction: 0.01) == .safe)
        #expect(Pace.evaluate(utilization: 60, elapsedFraction: 0.01) == .elevated)
    }

    @Test func unknownElapsedHidesPaceUnlessHigh() {
        #expect(Pace.evaluate(utilization: 42, elapsedFraction: nil) == nil)
        #expect(Pace.evaluate(utilization: 88, elapsedFraction: nil) == .elevated)
    }
}

@Suite("Formatters")
struct FormatterTests {
    @Test func tokenCounts() {
        #expect(Formatters.tokenCount(950) == "950")
        #expect(Formatters.tokenCount(184_300) == "184.3k")
        #expect(Formatters.tokenCount(52_500) == "52.5k")
        #expect(Formatters.tokenCount(813_001) == "813k")
        #expect(Formatters.tokenCount(2_800_000) == "2.8M")
        #expect(Formatters.tokenCount(1_700_000) == "1.7M")
    }

    @Test func countdowns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatters.countdown(to: now.addingTimeInterval(2 * 3600 + 46 * 60), now: now) == "2h 46m")
        #expect(Formatters.countdown(to: now.addingTimeInterval(4 * 86400 + 5 * 3600 + 59 * 60), now: now) == "4 days 5h 59m")
        #expect(Formatters.countdown(to: now.addingTimeInterval(30), now: now) == "<1m")
        #expect(Formatters.countdown(to: now.addingTimeInterval(23 * 60), now: now) == "23m")
    }

    @Test func modelDisplayNames() {
        #expect(ModelNames.display("claude-opus-4-8") == "opus-4.8")
        #expect(ModelNames.display("claude-haiku-4-5-20251001") == "haiku-4.5")
        #expect(ModelNames.display("claude-fable-5") == "fable-5")
        #expect(ModelNames.display("gpt-5.5") == "gpt-5.5")
        #expect(ModelNames.display("claude-sonnet-4-6") == "sonnet-4.6")
    }
}

@Suite("Pricing")
struct PricingTests {
    @Test func knownModelCost() {
        // 1M input + 1M output on opus-4-8 = $5 + $25.
        let cost = PricingTable.cost(
            model: "claude-opus-4-8",
            input: 1_000_000, output: 1_000_000,
            cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0
        )
        #expect(cost == 30)
    }

    @Test func cacheRates() {
        let pricing = PricingTable.pricing(forClaudeModel: "claude-fable-5")
        #expect(pricing?.cacheReadPerMTok == 1.0)
        #expect(pricing?.cacheWrite5mPerMTok == 12.5)
        #expect(pricing?.cacheWrite1hPerMTok == 20.0)
    }

    @Test func datedModelIDsMatch() {
        #expect(PricingTable.pricing(forClaudeModel: "claude-haiku-4-5-20251001") != nil)
    }

    @Test func legacyDatedIDsFallBackToBaseKeys() {
        // "claude-opus-4-20250514" contains no "opus-4-0"; the base key must catch it.
        #expect(PricingTable.pricing(forClaudeModel: "claude-opus-4-20250514")?.inputPerMTok == 15)
        #expect(PricingTable.pricing(forClaudeModel: "claude-sonnet-4-20250514")?.inputPerMTok == 3)
        // Longest-key matching keeps the specific entries authoritative.
        #expect(PricingTable.pricing(forClaudeModel: "claude-opus-4-8")?.inputPerMTok == 5)
        #expect(PricingTable.pricing(forClaudeModel: "claude-sonnet-4-6")?.inputPerMTok == 3)
    }

    @Test func unknownModelIsNil() {
        #expect(PricingTable.pricing(forClaudeModel: "gpt-5.5") == nil)
    }
}

@Suite("UsageMath")
struct UsageMathTests {
    @Test func rateSeriesComputesDeltas() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(date: now.addingTimeInterval(-3600), primary: 40, secondary: nil),
            UsageSample(date: now.addingTimeInterval(-1800), primary: 46, secondary: nil),
            UsageSample(date: now.addingTimeInterval(-900), primary: 44, secondary: nil),
        ]
        let series = UsageMath.rateSeries(samples: samples, window: 3600, bucket: 900, now: now)
        #expect(!series.isEmpty)
        let totalDelta = series.reduce(0) { $0 + $1.delta }
        #expect(abs(totalDelta - 4) < 0.001) // 40 → 44 overall
    }

    @Test func rateSeriesNeedsTwoSamples() {
        let now = Date.now
        let one = [UsageSample(date: now, primary: 50, secondary: nil)]
        #expect(UsageMath.rateSeries(samples: one, now: now).isEmpty)
    }

    @Test func rateSeriesBucketIdentitiesAreStableAcrossPolls() {
        // Two polls 30s apart inside the same 15-min bucket must produce
        // points with identical dates, or the chart re-animates wholesale.
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = [
            UsageSample(date: base.addingTimeInterval(-3600), primary: 40, secondary: nil),
            UsageSample(date: base.addingTimeInterval(-1800), primary: 46, secondary: nil),
        ]
        let first = UsageMath.rateSeries(samples: samples, now: base)
        let second = UsageMath.rateSeries(samples: samples, now: base.addingTimeInterval(30))
        #expect(!first.isEmpty)
        #expect(first.map(\.date) == second.map(\.date))
    }

    @Test func sevenDayFillsGaps() {
        let days = UsageMath.lastSevenDays(from: [:])
        #expect(days.count == 7)
        #expect(days.allSatisfy { $0.totals == .zero })
    }

    @Test func lastDaysAndMonthsBucketCorrectly() {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let fortyDaysAgo = calendar.date(byAdding: .day, value: -40, to: today)!
        let perDay: [Date: TokenTotals] = [
            today: TokenTotals(input: 10),
            fortyDaysAgo: TokenTotals(input: 7),
        ]

        let month = UsageMath.lastDays(30, from: perDay, calendar: calendar, now: now)
        #expect(month.count == 30)
        #expect(month.last?.totals.input == 10)
        #expect(month.map(\.totals.input).reduce(0, +) == 10) // 40d-old entry outside window

        let year = UsageMath.lastMonths(12, from: perDay, calendar: calendar, now: now)
        #expect(year.count == 12)
        #expect(year.last?.totals.input == 10)
        #expect(year.map(\.totals.input).reduce(0, +) == 17) // both fold into their months
    }

    @Test func hoursOfTodayBucketsByStartOfHour() {
        let calendar = Calendar.current
        let now = Date.now
        let dayStart = calendar.startOfDay(for: now)
        let nineAM = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let hours = UsageMath.hoursOfToday(
            from: [nineAM: TokenTotals(output: 42)],
            calendar: calendar,
            now: now
        )
        #expect(hours.count == 24)
        #expect(hours[9].totals.output == 42)
        #expect(hours[8].totals == .zero)
    }
}

@Suite("Color palettes")
@MainActor
struct PalettePaletteTests {
    /// Resolves a dynamic NSColor under a specific appearance.
    private func resolve(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func hex(_ color: NSColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    @Test func lightModeUsesAccessiblePalette() {
        #expect(hex(resolve(PulsePalette.ok, appearance: .aqua)) == "#248A3D")
        #expect(hex(resolve(PulsePalette.warn, appearance: .aqua)) == "#B25000")
        #expect(hex(resolve(PulsePalette.warnStrong, appearance: .aqua)) == "#C93400")
        #expect(hex(resolve(PulsePalette.critical, appearance: .aqua)) == "#D70015")
        #expect(hex(resolve(PulsePalette.info, appearance: .aqua)) == "#0040DD")
    }

    @Test func darkModeKeepsOriginalSystemColors() {
        let pairs: [(NSColor, NSColor)] = [
            (PulsePalette.ok, .systemGreen),
            (PulsePalette.warn, .systemYellow),
            (PulsePalette.warnStrong, .systemOrange),
            (PulsePalette.critical, .systemRed),
            (PulsePalette.info, .systemBlue),
        ]
        for (token, system) in pairs {
            #expect(
                hex(resolve(token, appearance: .darkAqua)) == hex(resolve(system, appearance: .darkAqua))
            )
        }
    }
}

@Suite("UsageStore resilience")
@MainActor
struct UsageStoreResilienceTests {
    private func snapshotWithGauge(_ id: ProviderID) -> UsageSnapshot {
        var snapshot = UsageSnapshot(providerID: id)
        snapshot.primary = LimitWindow(id: "p", title: "P", systemImage: "clock", utilization: 42)
        return snapshot
    }

    @Test func oneNotConnectedProbeKeepsTheSnapshot() {
        let store = UsageStore()
        store.apply(snapshotWithGauge(.cursor))

        store.applyNotConnected(.cursor, hint: "transient probe blip")
        #expect(store.record(for: .cursor).snapshot != nil) // first strike: keep data

        store.applyNotConnected(.cursor, hint: "really signed out")
        #expect(store.record(for: .cursor).snapshot == nil) // second strike: truthful empty state

        if case .notConnected = store.record(for: .cursor).displayState {} else {
            Issue.record("expected notConnected display state")
        }
    }

    @Test func successResetsNotConnectedStrikes() {
        let store = UsageStore()
        store.apply(snapshotWithGauge(.claude))
        store.applyNotConnected(.claude, hint: "blip")
        store.apply(snapshotWithGauge(.claude))
        store.applyNotConnected(.claude, hint: "blip again")
        #expect(store.record(for: .claude).snapshot != nil) // counter was reset by success
    }

    @Test func limitsUnavailableCarriesPreviousGaugesForward() {
        let store = UsageStore()
        store.apply(snapshotWithGauge(.claude))

        var degraded = UsageSnapshot(providerID: .claude)
        degraded.limitsUnavailable = true
        degraded.tokens = TokenUsageReport(
            today: TokenTotals(input: 1), thisMonth: TokenTotals(input: 1),
            modelBreakdown: [], showsCost: true
        )
        store.apply(degraded)

        let record = store.record(for: .claude)
        #expect(record.snapshot?.primary?.utilization == 42) // gauge survived the blip
        #expect(record.snapshot?.tokens != nil)
    }
}

@Suite("ProviderRecord activity")
struct ProviderRecordActivityTests {
    @Test func activityRequiresUsageOrUtilization() {
        var record = ProviderRecord()
        #expect(!record.isActiveRecently)

        var idle = UsageSnapshot(providerID: .gemini)
        idle.primary = LimitWindow(id: "q", title: "Q", systemImage: "gauge", utilization: 0)
        record.snapshot = idle
        #expect(!record.isActiveRecently)

        var active = UsageSnapshot(providerID: .claude)
        active.primary = LimitWindow(id: "s", title: "S", systemImage: "clock", utilization: 11)
        record.snapshot = active
        #expect(record.isActiveRecently)

        var usedThisWeek = UsageSnapshot(providerID: .codex)
        usedThisWeek.dailyUsage = [DailyUsage(date: .now, totals: TokenTotals(output: 5))]
        record.snapshot = usedThisWeek
        #expect(record.isActiveRecently)
    }
}

@Suite("LimitWindow")
struct LimitWindowTests {
    @Test func elapsedFromRollingWindow() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let window = LimitWindow(
            id: "five_hour", title: "5-Hour Session", systemImage: "clock",
            utilization: 42,
            resetsAt: now.addingTimeInterval(2 * 3600),
            windowDuration: 5 * 3600
        )
        let elapsed = window.elapsedFraction(now: now)
        #expect(elapsed != nil)
        #expect(abs(elapsed! - 0.6) < 0.001)
    }

    @Test func elapsedPrefersExplicitPeriod() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let window = LimitWindow(
            id: "plan", title: "Plan Usage", systemImage: "calendar",
            utilization: 10,
            resetsAt: now.addingTimeInterval(75 * 3600),
            periodStart: now.addingTimeInterval(-25 * 3600)
        )
        let elapsed = window.elapsedFraction(now: now)
        #expect(elapsed != nil)
        #expect(abs(elapsed! - 0.25) < 0.001)
    }
}

@Suite("TokenTotals")
struct TokenTotalsTests {
    @Test func costAdditionTreatsNilAsMissing() {
        var lhs = TokenTotals(input: 10, output: 5, cacheRead: 0, cacheWrite: 0, costUSD: nil)
        let rhs = TokenTotals(input: 1, output: 1, cacheRead: 2, cacheWrite: 3, costUSD: 0.5)
        lhs.add(rhs)
        #expect(lhs.input == 11)
        #expect(lhs.costUSD == 0.5)

        var bothNil = TokenTotals()
        bothNil.add(TokenTotals())
        #expect(bothNil.costUSD == nil)
    }
}
