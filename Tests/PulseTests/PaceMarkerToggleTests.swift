import Foundation
import Testing

@testable import Pulse

/// The pace tick is the only thing that turns "72%" into "ahead or behind", so
/// it defaults on. Turning it off must remove the mark *and* the space it
/// occupied, without disturbing the value the gauge reports.
@Suite("Pace marker toggle")
struct PaceMarkerToggleTests {
    private let clocked = LimitWindow(
        id: "five_hour", title: "5-Hour Session", systemImage: "clock",
        utilization: 60, resetsAt: Date(timeIntervalSince1970: 1_800_003_600),
        windowDuration: 5 * 3600
    )

    /// A per-model weekly cap reports `resets_at: null`, so no tick is
    /// derivable for it whatever the setting says.
    private let clockless = LimitWindow(
        id: "seven_day_opus", title: "Opus Weekly", systemImage: "sparkles",
        utilization: 12, resetsAt: nil, windowDuration: 7 * 86400
    )

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Mirrors `LimitGaugeCard.markerFraction`.
    private func markerFraction(show: Bool, _ window: LimitWindow) -> Double? {
        show ? window.elapsedFraction(now: now) : nil
    }

    /// Mirrors `GaugeBar.barHeight`.
    private func barHeight(paceMarker: Double?) -> CGFloat {
        paceMarker == nil
            ? Layout.progressBarHeight
            : Layout.progressBarHeight + Layout.paceMarkerOverhang
    }

    @Test func settingControlsOnlyTheTicksThatCouldBeDrawn() {
        #expect(markerFraction(show: true, clocked) != nil)
        #expect(markerFraction(show: false, clocked) == nil)
        #expect(markerFraction(show: true, clockless) == nil, "no clock, no tick")
        #expect(markerFraction(show: false, clockless) == nil)
    }

    /// The tick is decoration over the same data; hiding it must not move the
    /// bar or the number beside it.
    @Test(arguments: [SettingsStore.GaugeDirection.used, .remaining])
    func hidingTheTickLeavesTheReadingAlone(direction: SettingsStore.GaugeDirection) {
        let value = direction.displayValue(utilization: clocked.utilization)
        let fill = direction.fillFraction(utilization: clocked.utilization)
        #expect(value == direction.displayValue(utilization: clocked.utilization))
        #expect(fill == direction.fillFraction(utilization: clocked.utilization))
    }

    /// The tick stands proud of the bar, so a hidden tick has to give its
    /// overhang back rather than leaving an unexplained gap in the card.
    @Test func hiddenTickReclaimsItsLayoutSpace() {
        let withTick = barHeight(paceMarker: 0.4)
        let withoutTick = barHeight(paceMarker: nil)
        #expect(withoutTick < withTick)
        #expect(withTick - withoutTick == Layout.paceMarkerOverhang)
        #expect(withoutTick == Layout.progressBarHeight)
    }

    /// A clockless window never had a tick, so the setting must not change its
    /// row height in either position.
    @Test func clocklessRowsAreUnaffected() {
        let on = barHeight(paceMarker: markerFraction(show: true, clockless))
        let off = barHeight(paceMarker: markerFraction(show: false, clockless))
        #expect(on == off)
    }

    /// `bool(forKey:)` returns false for an absent key, which would ship the
    /// feature silently disabled for every existing user. The store reads it
    /// through `object(forKey:)` for exactly this reason.
    @Test func absentPreferenceDefaultsToOn() {
        let suite = "pulse-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect((defaults.object(forKey: "showPaceMarker") as? Bool) ?? true)
        #expect(defaults.bool(forKey: "showPaceMarker") == false, "the trap this avoids")

        defaults.set(false, forKey: "showPaceMarker")
        #expect(((defaults.object(forKey: "showPaceMarker") as? Bool) ?? true) == false)
        defaults.set(true, forKey: "showPaceMarker")
        #expect(((defaults.object(forKey: "showPaceMarker") as? Bool) ?? true) == true)
    }
}
