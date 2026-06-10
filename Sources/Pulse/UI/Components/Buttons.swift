import SwiftUI

/// Emil-style press feedback: scale 0.97 down, snappy zero-bounce release.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                configuration.isPressed ? Motion.pressDown : Motion.pressRelease,
                value: configuration.isPressed
            )
    }
}

/// Text button for the bottom bar: secondary → primary on hover with a soft
/// capsule behind, ≥24pt hit target.
struct BarButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typo.barButton)
                .foregroundStyle(tint ?? (isHovered ? Color.primary : Color.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isHovered ? PulseColor.cardFillHover : .clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(Motion.hover) { isHovered = hovering }
        }
    }
}

/// Ghost icon button (footer refresh): icon-only, hover brightens.
struct GhostIconButton: View {
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ThemedIcon(symbol: systemImage, pointSize: 11, weight: .medium)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusEffectDisabled()
        .help(help)
        .onHover { hovering in
            withAnimation(Motion.hover) { isHovered = hovering }
        }
    }
}
