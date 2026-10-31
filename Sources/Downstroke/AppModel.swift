import AppKit
import Combine
import DownstrokeCore
import QuartzCore

/// What the panel shows, derived from `AppController` so it can also be built by hand for snapshots.
struct PanelState: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var color: String
    }

    struct Section: Equatable, Identifiable {
        var texture: Texture
        var rows: [Row]
        var id: Texture { texture }
    }

    var enabled: Bool
    var status: String
    var permissionMissing: Bool
    var volume: Float
    var fixedStrength: Bool
    var sections: [Section]
    var currentBoardID: String
    var footer: String

    @MainActor
    init(_ c: AppController) {
        let s = c.settings
        enabled = s.enabled
        permissionMissing = c.permissionMissing
        volume = s.volume
        currentBoardID = s.boardID
        sections = Self.sections(c.boards)
        let boardName = c.boards.first { $0.id == s.boardID }?.name ?? s.boardID
        status = Self.status(
            enabled: s.enabled, permissionMissing: c.permissionMissing, frontmostBundleID: c.frontmostBundleID,
            mutedBundleIDs: s.mutedBundleIDs, micInUse: c.micInUse, muteWhileMicInUse: s.muteWhileMicInUse,
            boardName: boardName, hotkeyUnavailable: c.hotkeyError != nil, appName: Self.appName)
        switch c.sensorStatus {
        case .off, .unavailable: fixedStrength = true
        case .starting, .streaming, .stalled: fixedStrength = !s.hitStrengthEnabled
        }
        footer = Self.footer(p50: c.latencyP50, bluetooth: c.outputIsBluetooth)
    }

    init(
        enabled: Bool, status: String, permissionMissing: Bool, volume: Float, fixedStrength: Bool,
        sections: [Section], currentBoardID: String, footer: String
    ) {
        self.enabled = enabled
        self.status = status
        self.permissionMissing = permissionMissing
        self.volume = volume
        self.fixedStrength = fixedStrength
        self.sections = sections
        self.currentBoardID = currentBoardID
        self.footer = footer
    }

    static func sections(_ boards: [Board]) -> [Section] {
        Texture.allCases.compactMap { texture in
            let rows = boards.filter { $0.texture == texture }.map { Row(id: $0.id, name: $0.name, color: $0.color) }
            return rows.isEmpty ? nil : Section(texture: texture, rows: rows)
        }
    }

    static func status(
        enabled: Bool, permissionMissing: Bool, frontmostBundleID: String?, mutedBundleIDs: [String],
        micInUse: Bool, muteWhileMicInUse: Bool, boardName: String, hotkeyUnavailable: Bool = false,
        appName: (String) -> String
    ) -> String {
        if !enabled { return "Off" }
        if permissionMissing { return "Needs Input Monitoring" }
        if let app = frontmostBundleID, mutedBundleIDs.contains(app) { return "Muted in \(appName(app))" }
        if micInUse && muteWhileMicInUse { return "Muted: mic in use" }
        if hotkeyUnavailable { return "Hotkey unavailable" }
        return "Listening · \(boardName)"
    }

    static func footer(p50: Double?, bluetooth: Bool) -> String {
        if bluetooth { return "Bluetooth adds delay" }
        guard let p50 else { return "Key → sound — ms" }
        return "Key → sound \(Int((p50 * 1000).rounded())) ms"
    }

    static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}

/// Lit segments of the hit-strength meter; its own object so only the meter redraws at display rate.
@MainActor
final class MeterModel: ObservableObject {
    static let segments = 16
    static let decay = 0.3

    @Published private(set) var lit = 0

    private var seenCount: UInt32 = 0
    private var peak: Float = 0
    private var peakAt = 0.0

    func reset(count: UInt32) {
        seenCount = count
        peak = 0
        if lit != 0 { lit = 0 }
    }

    func step(press: (count: UInt32, velocity: Float), now: Double) {
        if press.count != seenCount {
            seenCount = press.count
            peak = press.velocity
            peakAt = now
        }
        let level = peak * Float(max(0, 1 - (now - peakAt) / Self.decay))
        let next = min(Self.segments, Int((level * Float(Self.segments)).rounded(.up)))
        if next != lit { lit = next }
    }

    func show(_ segments: Int) { lit = segments }
}

/// Panel-local UI state and actions: meter drive, hover auditions, volume drag.
@MainActor
final class PanelModel: NSObject, ObservableObject {
    static let hoverDelay: Duration = .milliseconds(400)

    @Published private(set) var hoveredBoard: String?
    @Published private(set) var dragVolume: Float?
    @Published private(set) var openCount = 0

    let meter = MeterModel()
    let controller: AppController
    var onOpenSettings: (() -> Void)?

    private var displayLink: CADisplayLink?
    private(set) var meterTicks = 0
    private var pendingAudition: Task<Void, Never>?

    init(controller: AppController) {
        self.controller = controller
    }

    // MARK: Panel lifecycle

    /// Before the panel orders front, so its first frame already scrolls to the current board.
    func willOpen() { openCount += 1 }

    func opened(on view: NSView) {
        meter.reset(count: controller.pipeline.lastPress.count)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func closed() {
        commitVolume()
        displayLink?.invalidate()
        displayLink = nil
        cancelHover()
        hoveredBoard = nil
        meter.reset(count: controller.pipeline.lastPress.count)
    }

    @objc private func tick(_ link: CADisplayLink) {
        meterTicks &+= 1
        meter.step(press: controller.pipeline.lastPress, now: CACurrentMediaTime())
    }

    // MARK: Boards

    func hover(_ id: String, inside: Bool) {
        if inside {
            guard hoveredBoard != id else { return }
            cancelHover()
            hoveredBoard = id
            pendingAudition = Task { [weak self] in
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled, let self, self.hoveredBoard == id else { return }
                self.pendingAudition = nil
                self.controller.audition(id)
            }
        } else if hoveredBoard == id {
            cancelHover()
            hoveredBoard = nil
        }
    }

    #if DEBUG
    func debugForceHover(_ id: String?) {
        cancelHover()
        hoveredBoard = id
    }
    #endif

    func play(_ id: String) {
        cancelHover()
        controller.audition(id)
    }

    func select(_ id: String) {
        cancelHover()
        controller.selectBoard(id)
    }

    private func cancelHover() {
        pendingAudition?.cancel()
        pendingAudition = nil
    }

    // MARK: Controls

    func setEnabled(_ on: Bool) { controller.setEnabled(on) }

    func dragVolume(_ volume: Float) {
        dragVolume = volume
        controller.previewVolume(volume)
    }

    func commitVolume() {
        guard let volume = dragVolume else { return }
        controller.setVolume(volume)
        dragVolume = nil
    }

    func requestPermission() { controller.requestPermission() }

    func openSettings() { onOpenSettings?() }
}
