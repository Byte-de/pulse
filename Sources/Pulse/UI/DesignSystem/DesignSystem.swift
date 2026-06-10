import AppKit
import SwiftUI

/// Motion tokens transcribed from docs/DESIGN.md §1. All motion is transform +
/// opacity + blur only; exits are faster and travel less than enters; data
/// never bounces. Every accessor honors Reduce Motion (rule 8).
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Reduce Motion replacement: a plain opacity-friendly crossfade.
    private static let reduced: Animation = .easeInOut(duration: 0.15)

    static var panelIn: Animation { reduceMotion ? reduced : .snappy(duration: 0.24, extraBounce: 0.06) }
    static var panelOut: Animation { reduceMotion ? reduced : .easeIn(duration: 0.14) }
    static var tabPill: Animation { reduceMotion ? reduced : .snappy(duration: 0.25, extraBounce: 0) }
    static var tabContentIn: Animation { reduceMotion ? reduced : .easeOut(duration: 0.18) }
    static var tabContentOut: Animation { reduceMotion ? reduced : .easeIn(duration: 0.12) }
    static var numberTick: Animation { reduceMotion ? reduced : .smooth(duration: 0.25) }
    static var gaugeFill: Animation { reduceMotion ? reduced : .spring(duration: 0.5, bounce: 0) }
    static var chartDrawIn: Animation { reduceMotion ? reduced : .easeOut(duration: 0.4) }
    static func chartBarStagger(_ index: Int) -> Animation {
        reduceMotion ? reduced : chartDrawIn.delay(Double(index) * 0.03)
    }
    static var hover: Animation { .easeOut(duration: 0.12) }
    static var pressDown: Animation { .easeOut(duration: 0.10) }
    static var pressRelease: Animation { reduceMotion ? reduced : .snappy(duration: 0.2, extraBounce: 0) }
    static var iconSwap: Animation { reduceMotion ? reduced : .smooth(duration: 0.2) }
    static var staleTint: Animation { .easeInOut(duration: 0.3) }
}

/// The app's two semantic color palettes, defined in ONE place at NSColor
/// level so resolution is unit-testable:
///
/// - **Dark mode** keeps the original vivid system colors — they were designed
///   for dark surfaces and clear HIG's 4.5:1 text contrast there.
/// - **Light mode** uses Apple's accessible palette (HIG Color →
///   Specifications): the vivid colors fall to ~2:1 on the light popover
///   material, which is exactly what "Increase Contrast" fixes system-wide.
///
/// Resolution is dynamic via `NSColor(name:dynamicProvider:)`, so every view
/// re-resolves automatically when the system appearance changes — no
/// observation, no manual invalidation.
enum PulsePalette {
    static let ok = dynamic(light: rgb(0x24, 0x8A, 0x3D), dark: .systemGreen)
    static let warn = dynamic(light: rgb(0xB2, 0x50, 0x00), dark: .systemYellow)
    static let warnStrong = dynamic(light: rgb(0xC9, 0x34, 0x00), dark: .systemOrange)
    static let critical = dynamic(light: rgb(0xD7, 0x00, 0x15), dark: .systemRed)
    static let info = dynamic(light: rgb(0x00, 0x40, 0xDD), dark: .systemBlue)

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}

/// SwiftUI-facing color tokens. Semantic state colors come from `PulsePalette`
/// (light = accessible, dark = original vivid) — call sites never choose an
/// appearance, only a meaning.
enum PulseColor {
    // §2.1 semantic palette
    static let ok = Color(nsColor: PulsePalette.ok)
    static let warn = Color(nsColor: PulsePalette.warn)
    static let warnStrong = Color(nsColor: PulsePalette.warnStrong)
    static let critical = Color(nsColor: PulsePalette.critical)
    static let info = Color(nsColor: PulsePalette.info)

    // §2.7 surfaces & hairlines
    static let cardFill = Color.primary.opacity(0.045)
    static let cardFillHover = Color.primary.opacity(0.085)
    static let hairline = Color(nsColor: .separatorColor)
    static let pillFill = Color.primary.opacity(0.09)
    static let trackFill = Color.primary.opacity(0.08)

    // §2.5 provider accents — identity only, never state.
    static func accent(_ id: ProviderID) -> Color {
        switch id {
        case .claude:
            Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex:
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0xD8 / 255, green: 0xD8 / 255, blue: 0xDC / 255, alpha: 1)
                    : NSColor(red: 0x4A / 255, green: 0x4A / 255, blue: 0x4F / 255, alpha: 1)
            })
        case .cursor:
            Color(red: 0x8C / 255, green: 0x7C / 255, blue: 0xCD / 255)
        case .copilot:
            Color(red: 0x6E / 255, green: 0x40 / 255, blue: 0xC9 / 255)
        case .gemini:
            Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255)
        }
    }

    /// §2.2 gauge thresholds: < 50% green, < 80% amber, else red.
    static func threshold(utilization: Double) -> Color {
        switch utilization {
        case ..<50: ok
        case ..<80: warn
        default: critical
        }
    }

    /// §2.4 trend semantics are INVERTED vs finance: usage rising is bad.
    static func trend(delta: Double) -> Color {
        if abs(delta) < 0.05 { return .secondary }
        return delta > 0 ? critical : ok
    }

    static func pace(_ pace: Pace) -> Color {
        switch pace {
        case .safe: ok
        case .elevated: warnStrong
        case .critical: critical
        }
    }
}

/// Geometry tokens from docs/DESIGN.md §3.2 (4pt grid, concentric radii:
/// inner = outer − inset).
enum Layout {
    static let panelWidth: CGFloat = 360
    static let panelRadius: CGFloat = 20
    static let panelPadding: CGFloat = 10
    static let cardRadius: CGFloat = 10 // panelRadius − panelPadding
    static let cardPadding: CGFloat = 12
    static let cardGap: CGFloat = 8
    static let tabBarHeight: CGFloat = 28
    static let bottomBarHeight: CGFloat = 36
    static let panelGap: CGFloat = 6
    static let screenMargin: CGFloat = 8
    static let progressBarHeight: CGFloat = 5
}

/// Type scale from docs/DESIGN.md §3.1. Every numeral is monospaced.
enum Typo {
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let gaugeValue = Font.system(size: 14, weight: .semibold).monospacedDigit()
    static let tabLabel = Font.system(size: 12, weight: .semibold)
    static let tableValue = Font.system(size: 12).monospacedDigit()
    static let tableLabel = Font.system(size: 12)
    static let caption = Font.system(size: 11, weight: .medium)
    static let captionValue = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let footer = Font.system(size: 11)
    static let barButton = Font.system(size: 12, weight: .medium)
    static let axisLabel = Font.system(size: 9, weight: .medium).monospacedDigit()
    static let menuBarValue = Font.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit()
    static let menuBarDelta = Font.system(size: 8, weight: .medium, design: .rounded).monospacedDigit()
    static let menuBarCode = Font.system(size: 7, weight: .bold)
}
