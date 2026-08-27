import Foundation
import Testing

@testable import Pulse

/// The gauge direction setting decides what a limit gauge *means*. Bar,
/// headline percentage and pace tick all derive from it, so they can never
/// disagree - a bar draining right-to-left beside a percentage counting up is
/// two contradictory claims about the same window.
@Suite("Gauge direction")
struct GaugeDirectionTests {
    private let used = SettingsStore.GaugeDirection.used
    private let remaining = SettingsStore.GaugeDirection.remaining

    @Test func percentageFollowsTheDirection() {
        #expect(used.displayValue(utilization: 72) == 72)
        #expect(remaining.displayValue(utilization: 72) == 28)
        #expect(used.displayValue(utilization: 0) == 0)
        #expect(remaining.displayValue(utilization: 0) == 100)
        #expect(used.displayValue(utilization: 100) == 100)
        #expect(remaining.displayValue(utilization: 100) == 0)
    }

    /// A provider may report over 100% after an overshoot; neither direction
    /// may render a negative percentage.
    @Test func overshootClamps() {
        #expect(remaining.displayValue(utilization: 137) == 0)
        #expect(used.fillFraction(utilization: 150) == 1)
        #expect(remaining.fillFraction(utilization: 150) == 0)
    }

    /// The invariant that makes the setting coherent: whatever number is
    /// printed, the bar is that long. This is what broke when the bar was
    /// reversed but the percentage was not.
    @Test(arguments: [SettingsStore.GaugeDirection.used, .remaining])
    func percentageAlwaysEqualsBarLength(direction: SettingsStore.GaugeDirection) {
        for step in 0...200 {
            let utilization = Double(step) / 2
            let shown = direction.displayValue(utilization: utilization)
            let filled = direction.fillFraction(utilization: utilization) * 100
            #expect(abs(shown - filled) < 0.0001, "diverged at \(utilization)% used")
        }
    }

    /// The tick tracks the fill's direction, so "fill meets tick" means "on
    /// pace" in both modes rather than flipping meaning with the setting.
    @Test func paceTickTracksTheFillDirection() {
        #expect(used.markerPosition(elapsedFraction: 0) == 0)
        #expect(used.markerPosition(elapsedFraction: 1) == 1)
        #expect(remaining.markerPosition(elapsedFraction: 0) == 1)
        #expect(remaining.markerPosition(elapsedFraction: 1) == 0)

        for direction in [used, remaining] {
            let fill = direction.fillFraction(utilization: 40)
            let tick = direction.markerPosition(elapsedFraction: 0.4)
            #expect(abs(fill - tick) < 0.0001, "even burn must put the fill on the tick")
        }
    }

    /// Over- and under-pace must stay legible in both modes, with the sides
    /// mirrored rather than the meaning changing.
    @Test func overAndUnderPaceReadCorrectly() {
        #expect(used.fillFraction(utilization: 80) > used.markerPosition(elapsedFraction: 0.2))
        #expect(remaining.fillFraction(utilization: 80) < remaining.markerPosition(elapsedFraction: 0.2))
        #expect(used.fillFraction(utilization: 20) < used.markerPosition(elapsedFraction: 0.6))
        #expect(remaining.fillFraction(utilization: 20) > remaining.markerPosition(elapsedFraction: 0.6))
    }

    @Test func theTwoModesAreExactMirrors() {
        for step in 0...100 {
            let utilization = Double(step)
            let fills = used.fillFraction(utilization: utilization)
                + remaining.fillFraction(utilization: utilization)
            let values = used.displayValue(utilization: utilization)
                + remaining.displayValue(utilization: utilization)
            #expect(abs(fills - 1) < 0.0001)
            #expect(abs(values - 100) < 0.0001)
        }
    }

    /// Persisted raw values are a storage contract: changing them silently
    /// resets everyone's preference to the default.
    @Test func persistsUnderStableRawValues() {
        #expect(used.rawValue == "used")
        #expect(remaining.rawValue == "remaining")
        #expect(SettingsStore.GaugeDirection(rawValue: "remaining") == remaining)
        #expect(SettingsStore.GaugeDirection(rawValue: "sideways") == nil)
        #expect(SettingsStore.GaugeDirection.allCases.count == 2)
    }
}
