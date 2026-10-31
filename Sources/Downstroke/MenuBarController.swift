import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let panel: PopoverPanel
    let model: PanelModel
    private let controller: AppController
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []
    private var enabledSink: AnyCancellable?

    init(controller: AppController) {
        self.controller = controller
        let model = PanelModel(controller: controller)
        self.model = model
        panel = PopoverPanel(content: PanelView(controller: controller, model: model))
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Downstroke")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        model.onOpenSettings = { [weak self] in
            self?.hidePanel()
            self?.controller.openSettings()
        }
        enabledSink = controller.$settings.map(\.enabled).removeDuplicates().sink { [weak self] on in
            self?.statusItem.button?.appearsDisabled = !on
        }
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard !panel.isVisible, let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(below: anchor, on: window.screen ?? NSScreen.main)
        button.highlight(true)
        model.opened(on: panel.contentView ?? button)
        installMonitors()
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.closed()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }) { monitors.append(m) }
        // Clicks in our own other windows; the status button toggles by itself.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self, event.window !== panel, event.window !== statusItem.button?.window else { return event }
            hidePanel()
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty {
                hidePanel()
                return nil
            }
            if flags == .command && event.charactersIgnoringModifiers == "," {
                model.openSettings()
                return nil
            }
            return event
        }) { monitors.append(m) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        })
    }
}

/// Built once at launch, laid out and drawn once offscreen, then only moved and ordered.
@MainActor
final class PopoverPanel: NSPanel {
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 5
    static let margin: CGFloat = 8

    private let hosting: FittingHostingView

    init(content: some View) {
        hosting = FittingHostingView(rootView: AnyView(content))
        let size = hosting.fittingSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        contentView = effect
        hosting.onInvalidate = { [weak self] in self?.fit() }
        warmUp()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Typing while the panel is key should still reach the meter, not beep.
    override func keyDown(with event: NSEvent) {}

    func show(below anchor: NSRect, on screen: NSScreen?) {
        fit()
        let size = frame.size
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.gap - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
            origin.y = max(origin.y, visible.minY + Self.margin)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
        makeKey()
    }

    /// Resizes to the SwiftUI content's fitting size, keeping the top edge in place.
    func fit() {
        let size = hosting.fittingSize
        guard size != frame.size, size.width > 0, size.height > 0 else { return }
        var next = frame
        next.origin.y = frame.maxY - size.height
        next.size = size
        setFrame(next, display: isVisible)
    }

    // Pays backing-store creation and SwiftUI's first layout and draw now, not on the first click.
    private func warmUp() {
        alphaValue = 0
        setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        orderFrontRegardless()
        contentView?.layoutSubtreeIfNeeded()
        display()
        orderOut(nil)
        alphaValue = 1
    }
}

final class FittingHostingView: NSHostingView<AnyView> {
    var onInvalidate: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onInvalidate?()
    }
}
