import AppKit
import SwiftUI

/// Borderless, non-activating floating panel under the status item.
/// Keyboard works while the previous app keeps focus; ESC, click-outside and
/// focus loss all dismiss through the same completion-driven hide path.
final class PulsePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none // content animates, never the window
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? PanelController)?.hide()
    }
}

/// Popover-material chrome with continuous rounded clipping and an adaptive
/// hairline. NSVisualEffectView clips its behind-window backdrop to the
/// rounded layer; NSGlassEffectView was tried first but leaves its backdrop
/// rectangle UNCLIPPED on borderless windows — a sharp-cornered sheet visibly
/// poking out behind the rounded panel.
final class PanelChromeView<Content: View>: NSView {
    private let effectView = NSVisualEffectView()
    private let hostingView: NSHostingView<Content>
    private let borderLayer = CAShapeLayer()
    private let cornerRadius: CGFloat

    init(rootView: Content, cornerRadius: CGFloat = Layout.panelRadius) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false // the NSWindow shadow lives outside our bounds

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        effectView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        effectView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        borderLayer.frame = bounds
    }

    override func updateLayer() {
        super.updateLayer()
        borderLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let environment: AppEnvironment
    private let panel: PulsePanel
    private let state = PanelState()

    private var contentHeight: CGFloat = 560
    private var monitors: [Any] = []
    private weak var statusButton: NSStatusBarButton?
    /// Where the panel hangs: captured at show-time from the CLICKED screen
    /// (the status item is replicated on every display's menu bar, but its
    /// backing window lives on only one of them).
    private var anchor: (screen: NSScreen, x: CGFloat, top: CGFloat)?
    var onVisibilityChange: ((Bool) -> Void)?
    var openSettings: (() -> Void)?

    private(set) var isPresented = false

    /// `--pin-panel` keeps the panel up despite focus loss / outside clicks —
    /// used only for automated screenshot verification.
    private let isPinnedForDebug = ProcessInfo.processInfo.arguments.contains("--pin-panel")

    init(environment: AppEnvironment) {
        self.environment = environment
        self.panel = PulsePanel(contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: 560))
        super.init()

        let rootView = PanelRootView(
            environment: environment,
            state: state,
            onHeightChange: { [weak self] height in self?.contentHeightChanged(height) },
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.openSettings?()
            }
        )
        panel.contentView = PanelChromeView(rootView: rootView)
        panel.delegate = self

        // Screenshot verification hooks: render the panel in a fixed
        // appearance regardless of the system setting.
        if ProcessInfo.processInfo.arguments.contains("--force-dark") {
            panel.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.arguments.contains("--force-light") {
            panel.appearance = NSAppearance(named: .aqua)
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isPresented {
            hide()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        statusButton = button
        isPresented = true
        anchor = Self.anchor(for: button)
        state.maxPanelHeight = (anchor?.screen.visibleFrame.height).map { $0 - 2 * Layout.screenMargin } ?? 700

        // Let SwiftUI report its natural height before the frame is committed.
        panel.contentView?.layoutSubtreeIfNeeded()
        position()

        state.isPresented = false
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
        environment.scheduler.refreshAll(ifOlderThan: 20)

        withAnimation(Motion.panelIn, completionCriteria: .logicallyComplete) {
            state.isPresented = true
        } completion: { [weak self] in
            // The shadow is derived from the rendered alpha; recompute it once
            // the content has fully appeared so no square ghost lingers.
            self?.panel.invalidateShadow()
        }
        onVisibilityChange?(true)
    }

    /// Resolves the screen the user actually clicked on (mouse location at
    /// show-time). When that differs from the screen hosting the status item's
    /// backing window, the item's x is mapped via its offset from the right
    /// edge — identical on every display's menu bar.
    private static func anchor(for button: NSStatusBarButton) -> (screen: NSScreen, x: CGFloat, top: CGFloat)? {
        let mouse = NSEvent.mouseLocation
        let clickedScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        let buttonRect = buttonWindow.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }

        guard let screen = clickedScreen ?? buttonScreen ?? NSScreen.main else { return nil }

        let x: CGFloat
        let top: CGFloat
        if let rect = buttonRect, let bScreen = buttonScreen, bScreen == screen {
            x = rect.midX
            top = rect.minY
        } else if let rect = buttonRect, let bScreen = buttonScreen {
            x = screen.frame.maxX - (bScreen.frame.maxX - rect.midX)
            top = screen.visibleFrame.maxY
        } else {
            x = mouse.x
            top = screen.visibleFrame.maxY
        }
        return (screen, x, top)
    }

    func hide() {
        guard isPresented, !isPinnedForDebug else { return }
        isPresented = false
        removeMonitors()
        statusButton?.highlight(false)

        withAnimation(Motion.panelOut, completionCriteria: .logicallyComplete) {
            state.isPresented = false
        } completion: { [weak self] in
            guard let self, !self.isPresented else { return }
            self.panel.orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    // MARK: - Geometry

    private func contentHeightChanged(_ height: CGFloat) {
        // The placeholder shown while hidden reports a 1pt height — ignore it.
        guard isPresented, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        position()
        panel.invalidateShadow()
    }

    /// Top edge stays pinned under the status item; height changes grow downward.
    private func position() {
        guard let anchor else { return }
        let visible = anchor.screen.visibleFrame

        let height = min(contentHeight, state.maxPanelHeight)
        var x = anchor.x - Layout.panelWidth / 2
        x = max(visible.minX + Layout.screenMargin,
                min(x, visible.maxX - Layout.panelWidth - Layout.screenMargin))
        let top = anchor.top - Layout.panelGap
        let y = max(visible.minY + Layout.screenMargin, top - height)

        panel.setFrame(
            NSRect(x: x, y: y, width: Layout.panelWidth, height: min(height, top - y)),
            display: true
        )
    }

    // MARK: - Dismissal

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.hide() }
        ) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                guard let self else { return event }
                let isPanel = event.window === self.panel
                // The status item's own window is excluded so its button action
                // can toggle without a double-fire race.
                let isStatusItem = event.window === self.statusButton?.window
                if !isPanel && !isStatusItem {
                    self.hide()
                }
                return event
            }
        ) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isPresented else { return }
        // Opening Settings (a regular window) legitimately takes key status.
        if NSApp.keyWindow == nil || NSApp.keyWindow === panel { hide() }
    }
}
