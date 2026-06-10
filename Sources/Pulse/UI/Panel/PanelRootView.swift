import Observation
import SwiftUI

/// Presentation state bridged from the AppKit panel controller into SwiftUI.
@MainActor
@Observable
final class PanelState {
    var isPresented = false
    /// Height budget for the whole panel (screen-derived, set by the controller).
    var maxPanelHeight: CGFloat = 700
}

/// Everything inside the glass: tab bar, card stack, footer, bottom bar.
/// The window is static at its final frame — all enter/exit motion happens here
/// (scale anchored .top + opacity + small upward offset).
struct PanelRootView: View {
    let environment: AppEnvironment
    let state: PanelState
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var slideDirection: CGFloat = 0
    @State private var cardsHeight: CGFloat = 400

    private var settings: SettingsStore { environment.settings }
    private var store: UsageStore { environment.store }

    private var tabs: [ProviderID] {
        settings.enabledProviders.isEmpty ? ProviderID.allCases : settings.enabledProviders
    }

    private var selection: ProviderID {
        tabs.contains(settings.selectedTab) ? settings.selectedTab : tabs[0]
    }

    var body: some View {
        // The tree only exists while presented: TimelineViews, tasks, and
        // store observation must not burn cycles behind an ordered-out window.
        ZStack(alignment: .top) {
            if state.isPresented {
                content
                    .frame(width: Layout.panelWidth)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                        onHeightChange(height)
                    }
                    .background(keyboardShortcuts)
                    .transition(panelTransition)
            } else {
                Color.clear.frame(width: Layout.panelWidth, height: 1)
            }
        }
    }

    /// Origin-aware enter/exit: grows out of the status item (scale anchored
    /// .top + opacity + small upward offset); Reduce Motion gets a plain fade.
    private var panelTransition: AnyTransition {
        guard !Motion.reduceMotion else { return .opacity }
        return .scale(scale: 0.96, anchor: .top)
            .combined(with: .opacity)
            .combined(with: .offset(y: -8))
    }

    private var content: some View {
        VStack(spacing: Layout.cardGap) {
            ProviderTabBar(
                providers: tabs,
                names: { environment.descriptor(for: $0).name },
                selection: Binding(
                    get: { selection },
                    set: { select($0, keyboard: false) }
                )
            )

            cardArea

            PanelFooter(store: store) {
                environment.scheduler.refreshAll()
            }

            PanelBottomBar(
                providerName: environment.descriptor(for: selection).name,
                openProvider: {
                    environment.openProvider(selection)
                    onClose()
                },
                openSettings: onOpenSettings,
                minimize: onClose,
                quit: { NSApp.terminate(nil) }
            )
        }
        .padding(Layout.panelPadding)
    }

    private var cardArea: some View {
        let chromeHeight: CGFloat = 200 // tab bar + footer + bottom bar + paddings
        let budget = max(state.maxPanelHeight - chromeHeight, 240)

        return ScrollView {
            ProviderDetailView(
                descriptor: environment.descriptor(for: selection),
                record: store.record(for: selection),
                settings: settings,
                retry: { environment.scheduler.refreshAll() },
                openSettings: onOpenSettings
            )
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                cardsHeight = height
            }
            .id(selection)
            .transition(tabTransition)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Hidden: the transient height race during tab transitions otherwise
        // flashes an overlay scroll bar for a frame.
        .scrollIndicators(.never)
        .frame(height: min(cardsHeight, budget))
        .animation(nil, value: cardsHeight)
    }

    private var tabTransition: AnyTransition {
        guard slideDirection != 0, !Motion.reduceMotion else {
            return .opacity.animation(.easeInOut(duration: 0.12))
        }
        return .asymmetric(
            insertion: .offset(x: slideDirection * 12).combined(with: .opacity)
                .animation(Motion.tabContentIn),
            removal: .offset(x: -slideDirection * 8).combined(with: .opacity)
                .animation(Motion.tabContentOut)
        )
    }

    private func select(_ id: ProviderID, keyboard: Bool) {
        guard id != selection else { return }
        let oldIndex = tabs.firstIndex(of: selection) ?? 0
        let newIndex = tabs.firstIndex(of: id) ?? 0
        // Keyboard-triggered switches get crossfade only (Motion rule 4).
        slideDirection = keyboard ? 0 : CGFloat(newIndex > oldIndex ? 1 : -1)
        withAnimation(Motion.tabPill) {
            settings.selectedTab = id
        }
    }

    private func cycleTab(_ step: Int) {
        guard let index = tabs.firstIndex(of: selection) else { return }
        let next = (index + step + tabs.count) % tabs.count
        select(tabs[next], keyboard: true)
    }

    /// Hidden buttons carrying the panel's keyboard shortcuts (the panel is key
    /// without activating the app, so these fire while another app keeps focus).
    private var keyboardShortcuts: some View {
        Group {
            Button("") { onClose() }.keyboardShortcut(.cancelAction)
            Button("") { environment.scheduler.refreshAll() }.keyboardShortcut("r", modifiers: .command)
            Button("") { onOpenSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            Button("") { cycleTab(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { cycleTab(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            ForEach(Array(tabs.prefix(4).enumerated()), id: \.offset) { index, id in
                Button("") { select(id, keyboard: true) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
