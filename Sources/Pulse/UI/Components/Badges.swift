import SwiftUI

/// Trend arrow + delta magnitude. Direction colors are usage-inverted
/// (up = consuming more = red); the glyph flips with a blur swap.
struct TrendBadge: View {
    let trend: Trend

    private var symbol: String {
        switch trend.direction {
        case .up: "arrowtriangle.up.fill"
        case .down: "arrowtriangle.down.fill"
        case .flat: "minus"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .transition(.blurReplace)
                .id(symbol)
            Text(Formatters.deltaPercent(trend.delta))
                .font(Typo.captionValue)
                .contentTransition(.numericText(value: abs(trend.delta)))
        }
        .foregroundStyle(PulseColor.trend(delta: trend.delta))
        .animation(Motion.iconSwap, value: trend.direction == .up)
    }
}

/// "Pace: safe" caption, colored by pace severity.
struct PaceLabel: View {
    let pace: Pace

    var body: some View {
        HStack(spacing: 3) {
            Text("Pace:")
                .foregroundStyle(.secondary)
            Text(pace.label)
                .foregroundStyle(PulseColor.pace(pace))
        }
        .font(Typo.caption)
        .animation(Motion.staleTint, value: pace)
    }
}

/// Tiny tertiary pill ("7d", "5h window") for card title accessories.
struct InfoTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(PulseColor.trackFill))
    }
}
