import AppKit
import Combine
import DownstrokeCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, sound, apps, diagnostics, about

    var title: String {
        switch self {
        case .general: "General"
        case .sound: "Sound"
        case .apps: "Apps"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sound: "speaker.wave.2"
        case .apps: "square.grid.2x2"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
}

/// A muted or running app as the Apps tab shows it.
struct AppInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage

    @MainActor private static var cache: [String: AppInfo] = [:]

    /// Running apps with a Dock presence, minus Downstroke, by name.
    @MainActor
    static func running() -> [AppInfo] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppInfo? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
                let info = AppInfo(id: id, name: app.localizedName ?? id, icon: app.icon ?? genericIcon)
                cache[id] = info
                return info
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Name and icon for a bundle ID, from a running copy or the app on disk, else the bare ID.
    @MainActor
    static func lookup(_ id: String) -> AppInfo {
        if let cached = cache[id] { return cached }
        let info: AppInfo
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            info = AppInfo(id: id, name: app.localizedName ?? id, icon: app.icon ?? genericIcon)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            info = AppInfo(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            info = AppInfo(id: id, name: id, icon: genericIcon)
        }
        cache[id] = info
        return info
    }

    @MainActor static var genericIcon: NSImage { NSWorkspace.shared.icon(for: .application) }
}

/// Window-local state: muted-app selection, the running-app menu, the licence sheet.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var selectedMuted: String?
    @Published private(set) var runningApps: [AppInfo] = []
    @Published var licence: LicenceNotice?

    let controller: AppController
    let recorder: HotkeyRecorderState
    private var observers: [any NSObjectProtocol] = []

    init(controller: AppController) {
        self.controller = controller
        recorder = HotkeyRecorderState(controller: controller)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
    }

    func refreshRunningApps() {
        let apps = AppInfo.running()
        if apps != runningApps { runningApps = apps }
    }

    /// Running apps not muted yet, for the "+" menu.
    var mutableApps: [AppInfo] {
        let muted = Set(controller.settings.mutedBundleIDs)
        return runningApps.filter { !muted.contains($0.id) }
    }

    func mute(_ id: String) {
        controller.update { if !$0.mutedBundleIDs.contains(id) { $0.mutedBundleIDs.append(id) } }
        selectedMuted = id
    }

    func unmuteSelected() {
        guard let id = selectedMuted else { return }
        controller.update { $0.mutedBundleIDs.removeAll { $0 == id } }
        selectedMuted = nil
    }
}

/// One licence file from LICENSES/, shown in the About tab.
struct LicenceNotice: Identifiable {
    let file: String
    let name: String
    let detail: String
    var id: String { file }

    static let all = [
        LicenceNotice(file: "switchcraft-MIT.txt", name: "Switchcraft", detail: "MIT License · © 2026 Mustafa Ahmed"),
        LicenceNotice(file: "mechvibes-MIT.txt", name: "Mechvibes", detail: "MIT License · © 2021 Hai Nguyen"),
        LicenceNotice(file: "kbsim-MIT.txt", name: "kbsim", detail: "MIT License · © Thomas Lai"),
        LicenceNotice(file: "apple-silicon-accelerometer-MIT.txt", name: "apple-silicon-accelerometer", detail: "MIT License · © 2026 olvvier"),
        LicenceNotice(file: "freesound-CC0.txt", name: "freesound recordings", detail: "CC0 1.0 · humi74, bonesawmgraw"),
    ]

    var text: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("LICENSES").appendingPathComponent(file) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// What the Diagnostics tab shows, sampled from the controller.
struct DiagnosticsSnapshot: Equatable {
    enum Health: Equatable { case good, warning, bad, idle }

    var permission = false
    var tap = "Stopped"
    var sensor = "Off"
    var sensorHealth = Health.idle
    var engine = "Off"
    var engineHealth = Health.idle
    var device = "None"
    var bluetooth = false
    var sampleRate = 0.0
    var ioFrames = 0
    var p50: Double?
    var p99: Double?
    var count = 0
    var voices = 0
    var slams = 0
    var problems: [String] = []

    static let maxVoices = 48

    static func ms(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.1f ms", seconds * 1000)
    }

    var sampleRateText: String { sampleRate > 0 ? "\(Int(sampleRate).formatted()) Hz" : "—" }

    var ioText: String {
        guard sampleRate > 0 else { return "\(ioFrames) frames" }
        return "\(ioFrames) frames · " + String(format: "%.1f ms", Double(ioFrames) / sampleRate * 1000)
    }

    /// Plain text for bug reports.
    var report: String {
        var lines = [
            "Downstroke \(AboutInfo.version)",
            "Input Monitoring: \(permission ? "granted" : "not granted")",
            "Key tap: \(tap)",
            "Motion sensor: \(sensor)",
            "Slams since launch: \(slams)",
            "Audio engine: \(engine)",
            "Output: \(device)\(bluetooth ? " (Bluetooth)" : "")",
            "Sample rate: \(sampleRateText)",
            "I/O buffer: \(ioText)",
            "Latency p50: \(Self.ms(p50)), p99: \(Self.ms(p99)), presses: \(count)",
            "Active voices: \(voices) of \(Self.maxVoices)",
        ]
        lines += problems
        return lines.joined(separator: "\n")
    }
}

/// Samples diagnostics at 4 Hz, only while the window shows the Diagnostics tab.
@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot = DiagnosticsSnapshot()
    private(set) var ticks = 0
    private(set) var isActive = false

    private let controller: AppController
    private var timer: Timer?
    private var rateSamples: [(time: Double, count: Int)] = []

    init(controller: AppController) {
        self.controller = controller
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        rateSamples.removeAll()
        guard active else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func sample() {
        ticks += 1
        let c = controller
        var s = DiagnosticsSnapshot()
        s.permission = KeyTap.hasPermission
        s.tap = c.listening ? "Listening" : !c.settings.enabled ? "Off" : c.permissionMissing ? "Waiting for permission" : "Stopped"
        (s.sensor, s.sensorHealth) = sensorText()
        (s.engine, s.engineHealth) = Self.engineText(c.idler.status, enabled: c.settings.enabled)
        s.device = SystemAudio.outputDeviceName ?? "None"
        s.bluetooth = c.outputIsBluetooth
        s.sampleRate = c.engine.sampleRate
        s.ioFrames = c.engine.ioBufferFrames
        s.p50 = c.latencyP50
        s.p99 = c.latencyP99
        s.count = c.latencyCount
        s.voices = c.mixer.activeVoices
        s.slams = c.pipeline.slamCount
        s.problems = (c.engineError.map { ["Audio engine: \($0)"] } ?? []) + c.packErrors.map { "Sound pack: \($0)" }
        if s != snapshot { snapshot = s }
    }

    static func engineText(_ status: EngineIdler.Status, enabled: Bool) -> (String, DiagnosticsSnapshot.Health) {
        switch status {
        case .running: ("Running", .good)
        case .paused: ("Paused (idle)", .idle)
        case .off: ("Off", enabled ? .warning : .idle)
        }
    }

    // Rate over the last second of ring appends.
    private func sensorRate() -> Double? {
        let now = MonotonicClock.now()
        rateSamples.append((now, controller.ring.count))
        rateSamples.removeAll { now - $0.time > 1.25 }
        guard let first = rateSamples.first, now - first.time >= 0.2 else { return nil }
        return Double(controller.ring.count - first.count) / (now - first.time)
    }

    private func sensorText() -> (String, DiagnosticsSnapshot.Health) {
        let rate = sensorRate()
        switch controller.sensorStatus {
        case .off:
            return (controller.settings.hitStrengthEnabled ? "Off while Downstroke is off" : "Off: slam accent is off", .idle)
        case .starting: return ("Starting…", .warning)
        case .streaming:
            guard let rate else { return ("Streaming", .good) }
            return ("Streaming at \(Int(rate.rounded())) Hz", .good)
        case .stalled: return ("Stalled: no samples for 0.5 s", .warning)
        case .unavailable(let reason): return ("Unavailable: \(reason)", .bad)
        }
    }
}

enum AboutInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// ⌘W closes, matched by key code like the panel's ⌘,.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown && event.keyCode == 13 && flags == .command {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Toolbar tabs that resize the window to each page's reported height, keeping its top edge.
final class SettingsTabController: NSTabViewController {
    var onSelect: (() -> Void)?
    // Pages report their own height; hosting controllers don't size the window, so nothing fights this.
    private var heights: [Int: CGFloat] = [:]

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: view.window?.isVisible == true)
        onSelect?()
    }

    func pageHeight(_ height: CGFloat, at index: Int) {
        guard heights[index] != height else { return }
        heights[index] = height
        if index == selectedTabViewItemIndex { fitWindow(animated: false) }
    }

    func fitWindow(animated: Bool) {
        let index = selectedTabViewItemIndex
        guard let window = view.window, tabViewItems.indices.contains(index) else { return }
        let height = heights[index] ?? tabViewItems[index].viewController?.view.fittingSize.height ?? 0
        guard height > 0 else { return }
        let size = NSSize(width: SettingsWindowController.width, height: height)
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        guard target != window.frame.size else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// The one Settings window, built on first open and reused.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 500

    let controller: AppController
    let model: SettingsModel
    let diagnostics: DiagnosticsModel
    private(set) var window: SettingsWindow?
    private var tabs: SettingsTabController?

    init(controller: AppController) {
        self.controller = controller
        model = SettingsModel(controller: controller)
        diagnostics = DiagnosticsModel(controller: controller)
        super.init()
        controller.onOpenSettings = { [weak self] in self?.show() }
    }

    var selectedTab: SettingsTab {
        guard let tabs, SettingsTab.allCases.indices.contains(tabs.selectedTabViewItemIndex) else { return .general }
        return SettingsTab.allCases[tabs.selectedTabViewItemIndex]
    }

    func show(_ tab: SettingsTab? = nil) {
        let window = window ?? build()
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) { tabs?.selectedTabViewItemIndex = index }
        controller.refreshLoginStatus()
        model.refreshRunningApps()
        if !window.isVisible { tabs?.fitWindow(animated: false) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateDiagnostics()
    }

    func close() { window?.performClose(nil) }

    private func build() -> SettingsWindow {
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in SettingsTab.allCases {
            let index = tabs.tabViewItems.count
            let host = NSHostingController(rootView: AnyView(page(tab).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak tabs] height in
                tabs?.pageHeight(height, at: index)
            }))
            host.sizingOptions = []
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        tabs.onSelect = { [weak self] in
            self?.model.recorder.stop()
            self?.updateDiagnostics()
        }
        self.tabs = tabs
        self.window = window
        tabs.fitWindow(animated: false)
        window.center()
        return window
    }

    private func page(_ tab: SettingsTab) -> AnyView {
        switch tab {
        case .general: AnyView(GeneralSettings(controller: controller, recorder: model.recorder))
        case .sound: AnyView(SoundSettings(controller: controller))
        case .apps: AnyView(AppsSettings(controller: controller, model: model))
        case .diagnostics: AnyView(DiagnosticsSettings(model: diagnostics, controller: controller))
        case .about: AnyView(AboutSettings(controller: controller, model: model))
        }
    }

    private func updateDiagnostics() {
        guard let window else { return diagnostics.setActive(false) }
        let visible = window.isVisible && window.occlusionState.contains(.visible)
        diagnostics.setActive(visible && selectedTab == .diagnostics)
    }

    func windowWillClose(_ notification: Notification) {
        model.recorder.stop()
        diagnostics.setActive(false)
    }

    func windowDidResignKey(_ notification: Notification) { model.recorder.stop() }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateDiagnostics() }
}
