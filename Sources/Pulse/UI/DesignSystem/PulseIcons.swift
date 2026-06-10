import AppKit
import SwiftUI

/// Bundled vector icons (Byte mark + the Nucleo set), loaded as template
/// images so they tint with the current foreground style exactly like
/// SF Symbols.
enum PulseIcons {
    /// The Byte "B" mark, extracted from the brand wordmark.
    static let byteMark: NSImage = {
        guard let url = Bundle.module.url(forResource: "ByteMark", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Pulse")
                ?? NSImage()
        }
        image.isTemplate = true
        return image
    }()

    /// SF Symbol name → bundled Nucleo asset (20×20 stroked SVGs). Views keep
    /// speaking SF Symbol names (providers store them in `LimitWindow`);
    /// anything unmapped falls back to the real SF Symbol.
    private static let nucleoBySymbol: [String: String] = [
        "clock": "clock",
        "calendar": "calendar",
        "chart.xyaxis.line": "chart-line",
        "chart.bar.fill": "chart-bar",
        "number": "hashtag",
        "slider.horizontal.3": "settings-slider",
        "gauge": "gauge",
        "sparkles": "sparkles",
        "sparkle": "sparkle",
        "dollarsign.circle": "dollar-circle",
        "arrow.clockwise": "arrow-clockwise",
        "checkmark": "checkmark",
        "minus": "minus",
        "xmark": "xmark",
        "exclamationmark.triangle": "exclamation-triangle",
        "key.slash": "questions-circle",
    ]

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(forSymbol symbol: String) -> NSImage? {
        if let cached = cache[symbol] { return cached }
        guard let asset = nucleoBySymbol[symbol],
              let url = Bundle.module.url(forResource: asset, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[symbol] = image
        return image
    }
}

/// Icon view that prefers the bundled Nucleo glyph and falls back to the
/// SF Symbol of the same name. Sized to match SF Symbols' optical size at the
/// given point size, so mixed usage lines up.
struct ThemedIcon: View {
    let symbol: String
    var pointSize: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        if let image = PulseIcons.image(forSymbol: symbol) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: pointSize * 1.2, height: pointSize * 1.2)
        } else {
            Image(systemName: symbol)
                .font(.system(size: pointSize, weight: weight))
        }
    }
}
