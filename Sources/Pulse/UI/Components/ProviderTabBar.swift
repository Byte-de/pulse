import SwiftUI

/// Capsule segmented control with a matched-geometry pill behind the active
/// provider. Inactive labels brighten on hover; the pill is reserved for
/// selection.
struct ProviderTabBar: View {
    let providers: [ProviderID]
    let names: (ProviderID) -> String
    @Binding var selection: ProviderID

    @Namespace private var pillNamespace
    @State private var hovered: ProviderID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(providers) { provider in
                segment(for: provider)
            }
        }
        .padding(2)
        .background(
            Capsule().fill(PulseColor.trackFill)
        )
        .frame(height: Layout.tabBarHeight)
    }

    private func segment(for provider: ProviderID) -> some View {
        let isActive = provider == selection
        return Button {
            withAnimation(Motion.tabPill) { selection = provider }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(PulseColor.accent(provider))
                    .frame(width: 5, height: 5)
                    .opacity(isActive ? 1 : 0.55)
                Text(names(provider))
                    .font(Typo.tabLabel)
                    .foregroundStyle(
                        isActive || hovered == provider ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: Layout.tabBarHeight - 4)
            .background {
                if isActive {
                    Capsule()
                        .fill(PulseColor.pillFill)
                        .matchedGeometryEffect(id: "tab-pill", in: pillNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(Motion.hover) { hovered = hovering ? provider : nil }
        }
    }
}
