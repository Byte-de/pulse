import SwiftUI

/// Header of one provider column in the side-by-side panel layout.
///
/// Carries what the tab bar carries in the tabbed layout — accent dot and
/// provider name — plus the per-column "open this provider" affordance, which
/// the bottom bar can no longer provide once several providers are on screen
/// at once. Clicking the name makes that provider the active one, which is
/// what the bottom bar and the next tabbed session use.
struct ProviderColumnHeader: View {
    let name: String
    let accent: Color
    let isActive: Bool
    let select: () -> Void
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .opacity(isActive ? 1 : 0.55)

            Button(action: select) {
                Text(name)
                    .font(Typo.tabLabel)
                    .foregroundStyle(isActive || isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer(minLength: 4)

            GhostIconButton(systemImage: "arrow.up.right", help: "Open \(name)", action: open)
        }
        .padding(.horizontal, 6)
        .frame(height: Layout.tabBarHeight)
        .background(
            Capsule().fill(isActive ? PulseColor.pillFill : PulseColor.trackFill)
        )
        .onHover { hovering in
            withAnimation(Motion.hover) { isHovered = hovering }
        }
    }
}
