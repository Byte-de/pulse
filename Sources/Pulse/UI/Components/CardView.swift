import SwiftUI

/// Flat tinted plate on the glass surface (never glass-on-glass): cardFill +
/// hairline, continuous corners, subtle hover. Cards are not buttons — no
/// lift, no shadow, no scale.
struct CardView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        content
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .fill(isHovered ? PulseColor.cardFillHover : PulseColor.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .strokeBorder(PulseColor.hairline.opacity(0.6), lineWidth: 1)
            )
            .geometryGroup()
            .onHover { hovering in
                withAnimation(Motion.hover) { isHovered = hovering }
            }
    }
}

/// Standard card header: tinted SF Symbol + title, with optional trailing
/// accessory (value, badge, ...).
struct CardTitleRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            ThemedIcon(symbol: systemImage, pointSize: 11)
                .foregroundStyle(PulseColor.ok)
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            accessory
        }
    }
}
