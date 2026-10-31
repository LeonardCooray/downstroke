#if DEBUG
import AppKit
import CoreGraphics
import DownstrokeCore
import Foundation
import SwiftUI

// Debug-only checks: `Downstroke --self-test <name>` prints PASS/FAIL lines and exits non-zero on any FAIL.
@MainActor
enum DebugSelfTest {
    private static var failures = 0

    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count else { return }
        Task { @MainActor in
            switch args[i + 1] {
            case "tap-reenable": tapReenable()
            case "sensor-restart": await sensorRestart()
            case "audio": await audio()
            case "audio-reconfigure": await audioReconfigure()
            case "mic": await mic()
            case "panel": await panel()
            case "panel-shots": await panelShots()
            default: check(false, "unknown self-test \(args[i + 1])")
            }
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func check(_ ok: Bool, _ name: String) {
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)")
    }

    static func tapReenable() {
        guard KeyTap.hasPermission else { return print("SKIP (no Input Monitoring)") }
        let tap = KeyTap()
        do {
            try tap.start()
        } catch {
            return check(false, "tap starts (\(error))")
        }
        defer { tap.stop() }
        check(tap.isTapEnabled, "tap enabled after start")
        for (type, name) in [(CGEventType.tapDisabledByTimeout, "timeout"), (.tapDisabledByUserInput, "user input")] {
            let r = tap.simulateSystemDisable(type)
            check(r.disabled, "tap disabled before the \(name) callback")
            check(r.reenabled, "tap re-enabled after disabled-by-\(name)")
        }
    }

    static func sensorRestart() async {
        let ring = SampleRing()
        let sensor = MotionSensor(ring: ring)
        for round in 1...2 {
            do {
                try sensor.start()
            } catch {
                return check(false, "sensor starts, round \(round) (\(error))")
            }
            try? await Task.sleep(for: .milliseconds(500))
            check(sensor.isStreaming, "sensor streams, round \(round)")
            // Catches a wrong timestamp unit: samples must sit on the MonotonicClock timebase.
            let lag = MonotonicClock.now() - (ring.latestTime ?? 0)
            check(lag >= 0 && lag < 0.05, "latest sample is on the MonotonicClock timebase, round \(round)")
            sensor.rewake()
            try? await Task.sleep(for: .milliseconds(200))
            check(sensor.isStreaming, "sensor streams after rewake, round \(round)")
            sensor.stop()
            check(!sensor.isRunning && !sensor.isStreaming, "sensor stops, round \(round)")
        }
    }

    static func audio() async {
        guard let (rig, bank) = startAudioRig() else { return }
        defer { rig.engine.stop() }
        await checkAuditionLatency(rig, bank, "audition")
        check(rig.engine.stats.renders.load(ordering: .relaxed) > 0, "render block runs")
    }

    static func audioReconfigure() async {
        guard let (rig, bank) = startAudioRig() else { return }
        defer { rig.engine.stop() }
        await checkAuditionLatency(rig, bank, "audition before the change")
        let before = rig.engine.engineIdentity
        var reconfigures = 0
        rig.engine.onReconfigure = { reconfigures += 1 }
        rig.engine.simulateConfigurationChange()
        try? await Task.sleep(for: .milliseconds(100))
        check(reconfigures == 1, "onReconfigure called once")
        check(rig.engine.engineIdentity != before, "engine rebuilt")
        check(rig.engine.isRunning, "engine running after the rebuild")
        let renders = rig.engine.stats.renders.load(ordering: .relaxed)
        await checkAuditionLatency(rig, bank, "audition after the change")
        check(rig.engine.stats.renders.load(ordering: .relaxed) > renders, "render block runs after the rebuild")
    }

    static func mic() async {
        func describe() -> String {
            guard let states = SystemAudio.processInputStates else { return "process list unavailable" }
            let inputs = states.filter(\.input).map { "\($0.pid)" }
            return "\(states.count) audio client processes, running input: [\(inputs.joined(separator: ", "))], ours \(getpid())"
        }
        let before = SystemAudio.micInUse
        print("  before engine: micInUse \(before); \(describe())")
        check(SystemAudio.processInputStates != nil, "process object list available")
        let rig = AudioRig()
        do { try rig.engine.start() } catch { return check(false, "engine starts (\(error))") }
        defer { rig.engine.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        let after = SystemAudio.micInUse
        print("  engine running: micInUse \(after); \(describe())")
        check(SystemAudio.processInputStates?.contains { $0.pid == getpid() && $0.input } == false,
              "our process is not running input")
        check(after == before, "our output engine does not change micInUse")
    }

    static func panel() async {
        // Seeded off, so start() loads boards and banks but runs no tap, engine or sensor.
        guard let defaults = isolatedDefaults() else { return check(false, "isolated defaults suite") }
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.save()
        let controller = AppController(defaults: defaults)
        controller.start()
        let menuBar = MenuBarController(controller: controller)
        var settingsOpened = 0
        controller.onOpenSettings = { settingsOpened += 1 }
        try? await Task.sleep(for: .milliseconds(300))

        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let t0 = MonotonicClock.now()
        menuBar.showPanel()
        let openMs = (MonotonicClock.now() - t0) * 1000
        check(openMs < 16, String(format: "panel opens in under 16 ms (%.2f ms)", openMs))
        check(menuBar.panel.isVisible, "panel visible after the status item opens it")
        check(menuBar.panel.isKeyWindow, "panel is key")
        check(menuBar.panel.frame.width == PanelContent.width, "panel is \(Int(PanelContent.width)) pt wide (\(menuBar.panel.frame.width))")
        if let button = menuBar.statusItem.button, let window = button.window, let screen = window.screen {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let frame = menuBar.panel.frame
            check(frame.maxY <= anchor.minY && screen.visibleFrame.contains(frame), "panel sits below the status item, on its screen")
        }
        try? await Task.sleep(for: .milliseconds(300))
        let ticks = menuBar.model.meterTicks
        check(ticks >= 10, "meter display link ticks while open (\(ticks) in ~0.3 s)")
        let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check(frontAfter == frontBefore && frontAfter != getpid(), "frontmost app unchanged by the panel (pid \(frontAfter ?? -1))")

        // SwiftUI exposes no identifiers without an accessibility client, so this checks the state the view renders.
        let state = PanelState(controller)
        let headings = state.sections.map(\.texture.rawValue)
        check(headings == Texture.allCases.map(\.rawValue), "texture headings in order: \(headings.joined(separator: ", "))")
        let rows = state.sections.flatMap(\.rows)
        check(rows.count == 20, "20 board rows (\(rows.count))")
        check(state.status == "Off" && state.fixedStrength, "status Off and fixed strength while disabled")

        let target = rows.map(\.id).first { $0 != controller.settings.boardID } ?? ""
        menuBar.model.select(target)
        check(controller.settings.boardID == target, "selecting the \(target) row sets settings.boardID (now \(controller.settings.boardID))")
        check(SettingsStore(defaults: defaults).settings.boardID == target, "selection saved to the isolated suite")

        // Escape and Cmd-comma through the app's own event queue, as the panel receives them.
        postKey(53, characters: "\u{1b}", window: menuBar.panel)
        try? await Task.sleep(for: .milliseconds(150))
        check(!menuBar.panel.isVisible, "Escape closes the panel")
        let closedTicks = menuBar.model.meterTicks
        try? await Task.sleep(for: .milliseconds(100))
        check(menuBar.model.meterTicks == closedTicks, "meter stops ticking once closed")
        menuBar.showPanel()
        try? await Task.sleep(for: .milliseconds(100))
        postKey(43, characters: ",", flags: .command, window: menuBar.panel)
        try? await Task.sleep(for: .milliseconds(150))
        check(settingsOpened == 1, "Cmd-comma opens Settings (\(settingsOpened) calls)")
        check(!menuBar.panel.isVisible, "opening Settings closes the panel")

        menuBar.showPanel()
        try? await Task.sleep(for: .milliseconds(100))
        let other = NSPanel(contentRect: NSRect(x: -9000, y: -9000, width: 40, height: 40), styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(150))
        check(!menuBar.panel.isVisible, "losing key status closes the panel")
        other.orderOut(nil)
        check(settingsOpened == 1, "still exactly one Settings call (\(settingsOpened))")

        var times: [Double] = []
        for _ in 0..<5 {
            let t = MonotonicClock.now()
            menuBar.showPanel()
            times.append((MonotonicClock.now() - t) * 1000)
            try? await Task.sleep(for: .milliseconds(50))
            menuBar.hidePanel()
            try? await Task.sleep(for: .milliseconds(50))
        }
        times.sort()
        check(times[2] < 16, String(format: "reopen median under 16 ms (%.2f ms, max %.2f)", times[2], times[4]))

        controller.setEnabled(false)
        check(menuBar.statusItem.button?.appearsDisabled == true, "menu bar glyph dimmed while off")

        let meter = MeterModel()
        meter.reset(count: 0)
        meter.step(press: (1, 1.0), now: 10)
        check(meter.lit == 16, "full hit lights 16 segments (\(meter.lit))")
        meter.step(press: (1, 1.0), now: 10.15)
        check(meter.lit == 8, "half decayed after 150 ms (\(meter.lit))")
        meter.step(press: (1, 1.0), now: 10.3)
        check(meter.lit == 0, "dark after 300 ms (\(meter.lit))")
        meter.step(press: (2, 0.5), now: 11)
        check(meter.lit == 8, "a new press re-arms the meter (\(meter.lit))")

        let name = { (id: String) in id == "us.zoom.xos" ? "zoom.us" : id }
        func status(enabled: Bool = true, permission: Bool = false, front: String? = nil, mic: Bool = false) -> String {
            PanelState.status(
                enabled: enabled, permissionMissing: permission, frontmostBundleID: front, mutedBundleIDs: ["us.zoom.xos"],
                micInUse: mic, muteWhileMicInUse: true, boardName: "Holy Panda", appName: name)
        }
        check(status() == "Listening · Holy Panda", "status: listening")
        check(status(enabled: false, permission: true) == "Off", "status: off")
        check(status(permission: true) == "Needs Input Monitoring", "status: needs Input Monitoring")
        check(status(front: "us.zoom.xos", mic: true) == "Muted in zoom.us", "status: muted app")
        check(status(front: "com.apple.Notes", mic: true) == "Muted: mic in use", "status: mic in use")
        check(PanelState.footer(p50: 0.0094, bluetooth: false) == "Key → sound 9 ms", "footer: p50 rounded")
        check(PanelState.footer(p50: nil, bluetooth: false) == "Key → sound — ms", "footer: no data")
        check(PanelState.footer(p50: 0.02, bluetooth: true) == "Bluetooth adds delay", "footer: Bluetooth")
        menuBar.hidePanel()
        defaults.removePersistentDomain(forName: AudioRig.isolatedSuite)
    }

    /// Renders the panel in fixed states to build/panel-*.png, plus window captures if screencapture is allowed.
    static func panelShots() async {
        guard let defaults = isolatedDefaults() else { return check(false, "isolated defaults suite") }
        let boards = BundledPacks.load().0
        let model = PanelModel(controller: AppController(defaults: defaults))
        model.meter.show(11)
        let listening = PanelState(
            enabled: true, status: "Listening · Holy Panda", permissionMissing: false, volume: 0.68, fixedStrength: false,
            sections: PanelState.sections(boards), currentBoardID: "holy-panda", footer: "Key → sound 9 ms")
        var permission = listening
        permission.status = "Needs Input Monitoring"
        permission.permissionMissing = true
        permission.footer = "Key → sound — ms"
        var scrolled = listening
        scrolled.currentBoardID = "cherry-mx-clear"
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        let shots: [(String, PanelState, NSAppearance.Name)] = [
            ("light", listening, .aqua), ("dark", listening, .darkAqua),
            ("permission-dark", permission, .darkAqua), ("scrolled-dark", scrolled, .darkAqua),
        ]
        for (name, state, appearance) in shots {
            model.debugForceHover(nil)
            let panel = PopoverPanel(content: PanelContent(state: state, model: model))
            panel.appearance = NSAppearance(named: appearance)
            let screen = NSScreen.main!.visibleFrame
            panel.show(below: NSRect(x: screen.minX + 40, y: screen.maxY, width: 24, height: 0), on: NSScreen.main)
            try? await Task.sleep(for: .milliseconds(300))
            // Forced after the tracking areas settle, which report the real pointer as outside.
            if name == "light" { model.debugForceHover("topre") }
            try? await Task.sleep(for: .milliseconds(200))
            let file = out.appendingPathComponent("panel-\(name).png")
            check(renderOffscreen(panel, dark: appearance == .darkAqua, to: file), "rendered \(file.path)")
            let window = out.appendingPathComponent("panel-window-\(name).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(panel.windowNumber)", window.path]
            try? p.run()
            p.waitUntilExit()
            let size = (try? FileManager.default.attributesOfItem(atPath: window.path)[.size] as? Int) ?? 0
            print(p.terminationStatus == 0 && size > 0 ? "  captured \(window.path)" : "  screencapture failed (status \(p.terminationStatus)); Screen Recording likely not granted")
            panel.orderOut(nil)
        }
    }

    private static func isolatedDefaults() -> UserDefaults? {
        guard let defaults = UserDefaults(suiteName: AudioRig.isolatedSuite) else { return nil }
        defaults.removePersistentDomain(forName: AudioRig.isolatedSuite)
        return defaults
    }

    private static func postKey(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    // The behind-window material can't be cached, so it is approximated over a backdrop.
    private static func renderOffscreen(_ panel: NSPanel, dark: Bool, to url: URL) -> Bool {
        guard let view = panel.contentView?.subviews.first, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        let pad: CGFloat = 36
        let size = NSSize(width: view.bounds.width + pad * 2, height: view.bounds.height + pad * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let backdrop = dark
            ? NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.27, alpha: 1), ending: NSColor(srgbRed: 0.30, green: 0.22, blue: 0.33, alpha: 1))
            : NSGradient(starting: NSColor(srgbRed: 0.62, green: 0.72, blue: 0.86, alpha: 1), ending: NSColor(srgbRed: 0.86, green: 0.78, blue: 0.84, alpha: 1))
        backdrop?.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        let rect = NSRect(x: pad, y: pad, width: view.bounds.width, height: view.bounds.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: PopoverPanel.cornerRadius, yRadius: PopoverPanel.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        (dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.94) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 0.94)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        rep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private static func startAudioRig() -> (AudioRig, SampleBank)? {
        let rig = AudioRig()
        let bank: SampleBank
        do { bank = try rig.bank(rig.settings.boardID) } catch {
            check(false, "\(rig.settings.boardID) bank loads (\(error))")
            return nil
        }
        rig.pipeline.update(settings: rig.settings, bank: bank, sensorAvailable: false)
        rig.mixer.setMasterGain(rig.settings.volume)
        do { try rig.engine.start() } catch {
            check(false, "engine starts (\(error))")
            return nil
        }
        check(rig.engine.isRunning, "engine running at \(Int(rig.engine.sampleRate)) Hz, I/O buffer \(rig.engine.ioBufferFrames) frames")
        return (rig, bank)
    }

    private static func checkAuditionLatency(_ rig: AudioRig, _ bank: SampleBank, _ name: String) async {
        _ = rig.drainLatencies()
        print(String(format: "  render lead before \(name): %.2f ms", rig.engine.stats.lead * 1000))
        rig.pipeline.audition(boardBank: bank)
        let deadline = MonotonicClock.now() + 0.2
        var latency: Double?
        while latency == nil && MonotonicClock.now() < deadline {
            latency = rig.drainLatencies().first
            if latency == nil { try? await Task.sleep(for: .milliseconds(2)) }
        }
        guard let latency else { return check(false, "\(name) produces a latency sample within 200 ms") }
        check(true, "\(name) produces a latency sample within 200 ms")
        // Catches a host-time unit mix-up: mach ticks read as nanoseconds are 41x off on Apple silicon.
        check(latency > 0 && latency < 0.1, String(format: "\(name) latency is plausible (%.2f ms)", latency * 1000))
    }
}
#endif
