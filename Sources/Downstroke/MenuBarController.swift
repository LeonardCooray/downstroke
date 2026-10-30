import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = PopoverPanel()
    private var outsideClickMonitor: Any?

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Downstroke")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(below: anchor)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }
}

/// Built once at launch and reused; the controls arrive in a later task.
@MainActor
final class PopoverPanel: NSPanel {
    static let size = NSSize(width: 360, height: 480)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    override var canBecomeKey: Bool { false }

    func show(below anchor: NSRect) {
        var origin = NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - 6)
        if let screen = NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Self.size.width - 8)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}
