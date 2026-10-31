#if DEBUG
import AppKit
import CoreGraphics
import DownstrokeCore
import Carbon.HIToolbox
import Foundation
import ServiceManagement
import SwiftUI

// Debug-only checks: `Downstroke --self-test <name>` prints PASS/FAIL lines and exits non-zero on any FAIL.
/// Stands in for SMAppService.mainApp so self-tests never touch the real login item.
@MainActor
final class FakeLoginItem: LoginItemService {
    var status = SMAppService.Status.notRegistered
    var failure: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        registerCalls += 1
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

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
            case "engine-pause": await enginePause()
            case "mic": await mic()
            case "panel": await panel()
            case "panel-shots": await panelShots()
            case "settings": await settings()
            case "settings-shots": await settingsShots()
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

    static func enginePause() async {
        // Volume 0 and fixed strength: presses emit at once and stay silent; 1 s idle timeout.
        guard let defaults = isolatedDefaults() else { return check(false, "isolated defaults suite") }
        let seed = SettingsStore(defaults: defaults)
        seed.settings.volume = 0
        seed.settings.hitStrengthEnabled = false
        seed.save()
        let controller = AppController(defaults: defaults, loginItems: FakeLoginItem(), engineIdleTimeout: 1)
        controller.start()
        let idler = controller.idler, engine = controller.engine
        let diagnostics = DiagnosticsModel(controller: controller)
        func engineRow() -> String {
            diagnostics.sample()
            return diagnostics.snapshot.engine
        }
        func waitPaused(_ limit: Double = 3) async -> Double? {
            await waitUntil(limit) { idler.status == .paused }
        }
        func pressAndMeasure(_ name: String) async {
            // Long enough paused for the output device to need a full restart.
            try? await Task.sleep(for: .seconds(1))
            let count = controller.latencyCount, stale = controller.mixer.staleTriggers, renders = engine.stats.renders.load(ordering: .relaxed)
            press { controller.simulateKeyEvent($0) }
            let woke = await waitUntil(1) { controller.latencyCount > count }
            check(woke != nil && engine.isRunning, "\(name): key wakes the engine and its press reaches the latency readout")
            let first = woke != nil ? controller.lastLatency ?? 1 : 1
            check(first > 0 && first < 0.05, String(format: "\(name): first key after the pause plays within 50 ms (%.2f ms, output time)", first * 1000))
            try? await Task.sleep(for: .milliseconds(100))
            press { controller.simulateKeyEvent($0) }
            let next = await waitUntil(1) { controller.latencyCount > count + 1 }
            let second = next != nil ? controller.lastLatency ?? 1 : 1
            check(second < 0.015, String(format: "\(name): the next key is back to normal (%.2f ms)", second * 1000))
            if let wake = idler.lastWake {
                print(String(format: "  wake hop to main %.2f ms, engine start %.2f ms", wake.hop * 1000, wake.start * 1000))
            }
            check(controller.mixer.staleTriggers == stale, "\(name): the first key is not dropped as stale")
            check(engine.stats.renders.load(ordering: .relaxed) > renders, "\(name): render block runs again")
        }

        check(engine.isRunning && idler.status == .running, "engine running after start")
        check(engineRow() == "Running", "Diagnostics engine row: Running")
        if let t = await waitPaused() {
            check(true, String(format: "engine pauses after 1 s idle with no voices (%.2f s after the wait began)", t))
        } else {
            return check(false, "engine pauses after 1 s idle with no voices")
        }
        check(!engine.isRunning, "paused engine is not rendering")
        check(engineRow() == "Paused (idle)", "Diagnostics engine row: Paused (idle)")
        controller.update { $0.stereoWidth = 0.3 }
        check(idler.status == .paused, "a settings change leaves the paused engine paused")

        await pressAndMeasure("after idle")
        check(idler.wakes == 1, "one wake for one pause (\(idler.wakes))")
        check(engineRow() == "Running", "Diagnostics engine row back to Running")

        // A slowed, silent clip keeps a voice sounding well past the timeout.
        guard await waitPaused() != nil else { return check(false, "engine pauses again") }
        press { controller.simulateKeyEvent($0) }
        guard await waitUntil(1, { engine.isRunning }) != nil,
              let board = controller.boards.first(where: { $0.id == controller.settings.boardID }),
              let bank = try? SampleBank(board: board, sampleRate: engine.sampleRate),
              let clip = bank.presses(.alpha, .hard).first
        else { return check(false, "engine wakes and a clip loads for the sounding-voice check") }
        let rate = Float(Double(clip.frames) / engine.sampleRate / 3)
        _ = controller.queue.push(Trigger(clip: clip, gain: 0, pan: 0, rate: rate, eventTime: MonotonicClock.now(), bankTag: bank.tag))
        try? await Task.sleep(for: .milliseconds(2000))
        check(engine.isRunning && controller.mixer.activeVoices > 0,
              "no pause while a voice is sounding (\(controller.mixer.activeVoices) voices, 2 s after the last key)")
        let ended = await waitPaused(4)
        check(ended != nil && controller.mixer.activeVoices == 0, "pauses once the voice ends")
        withExtendedLifetime(bank) {}

        let boardID = controller.settings.boardID
        let renders = engine.stats.renders.load(ordering: .relaxed)
        controller.audition(boardID)
        check(engine.isRunning && idler.status == .running, "audition wakes the paused engine before it queues")
        let voiced = await waitUntil(0.3) { controller.mixer.activeVoices > 0 }
        check(voiced != nil && engine.stats.renders.load(ordering: .relaxed) > renders, "the audition renders a voice")

        guard await waitPaused(4) != nil else { return check(false, "engine pauses after the audition") }
        let before = engine.engineIdentity
        var reconfigures = 0
        let realReconfigure = engine.onReconfigure
        engine.onReconfigure = {
            reconfigures += 1
            realReconfigure?()
        }
        engine.simulateConfigurationChange()
        try? await Task.sleep(for: .milliseconds(150))
        check(reconfigures == 1 && engine.engineIdentity != before, "configuration change while paused rebuilds the engine")
        check(idler.status == .paused && !engine.isRunning, "and it stays paused, not running")
        await pressAndMeasure("after a configuration change while paused")
        check(engine.sampleRate > 0 && engine.ioBufferFrames > 0, "rebuilt engine at \(Int(engine.sampleRate)) Hz, \(engine.ioBufferFrames) frames")

        // A restart slower than the 0.25 s stale guard still plays the waking key.
        guard await waitPaused() != nil else { return check(false, "engine pauses before the slow-restart check") }
        let staleBefore = controller.mixer.staleTriggers, countBefore = controller.latencyCount
        engine.simulatedStartDelay = 0.4
        press { controller.simulateKeyEvent($0) }
        let slow = await waitUntil(2) { controller.latencyCount > countBefore }
        engine.simulatedStartDelay = 0
        let slowLatency = slow != nil ? controller.lastLatency ?? 0 : 0
        check(slow != nil && slowLatency > 0.25 && controller.mixer.staleTriggers == staleBefore,
              String(format: "a 0.4 s restart still plays the waking key (%.2f ms, none dropped as stale)", slowLatency * 1000))
        try? await Task.sleep(for: .milliseconds(600))
        check(!controller.mixer.hasWakeMark, "the wake mark clears once the engine has rendered")

        // A failed wake reads Off and retries at most once a second.
        guard await waitPaused() != nil else { return check(false, "engine pauses before the failed-wake check") }
        let attempts = idler.wakes, staleBeforeFail = controller.mixer.staleTriggers
        engine.simulatedStartFailure = NSError(domain: "DownstrokeSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated start failure"])
        press { controller.simulateKeyEvent($0) }
        _ = await waitUntil(1) { idler.wakes > attempts }
        diagnostics.sample()
        check(idler.wakes == attempts + 1 && idler.status == .off && diagnostics.snapshot.engine == "Off"
              && diagnostics.snapshot.engineHealth == .warning && controller.engineError != nil,
              "a failed wake shows Off (orange) with the error (\(controller.engineError ?? "no error"))")
        press { controller.simulateKeyEvent($0) }
        try? await Task.sleep(for: .milliseconds(200))
        check(idler.wakes == attempts + 1 && !engine.isRunning, "a second key within 1 s doesn't retry the start")
        engine.simulatedStartFailure = nil
        try? await Task.sleep(for: .milliseconds(900))
        let countRetry = controller.latencyCount
        press { controller.simulateKeyEvent($0) }
        let retried = await waitUntil(1) { controller.latencyCount > countRetry }
        check(retried != nil && engine.isRunning && idler.wakes == attempts + 2 && controller.engineError == nil,
              "after a second, the next key retries, starts the engine and plays")
        try? await Task.sleep(for: .milliseconds(300))
        check(controller.latencyCount == countRetry + 1 && controller.mixer.staleTriggers > staleBeforeFail,
              "the two keys that hit the failed engine are dropped as stale, not replayed (\(controller.mixer.staleTriggers - staleBeforeFail) triggers dropped)")

        // Wanted running but not rendering: a leftover wake mark must still clear.
        engine.simulatedStartFailure = NSError(domain: "DownstrokeSelfTest", code: 2)
        engine.stop()
        try? idler.start()
        engine.simulatedStartFailure = nil
        controller.mixer.setWakeMark(MonotonicClock.now())
        try? await Task.sleep(for: .milliseconds(400))
        check(idler.status == .off && !controller.mixer.hasWakeMark, "a wake mark clears when the engine stops without idling")
        try? idler.start()

        guard await waitPaused() != nil else { return check(false, "engine pauses before the disable check") }
        controller.setEnabled(false)
        check(idler.status == .off && engineRow() == "Off", "turning Downstroke off stops a paused engine (row: Off)")
        let wakes = idler.wakes
        press { controller.simulateKeyEvent($0) }
        try? await Task.sleep(for: .milliseconds(300))
        check(idler.wakes == wakes && idler.status == .off, "keys while off don't wake it")
        controller.setEnabled(true)
        check(idler.status == .running, "turning Downstroke on starts it")

        // The sensor keeps streaming while the engine is paused.
        controller.update { $0.hitStrengthEnabled = true }
        if let t = await waitPaused() {
            let streaming = await waitUntil(1.5) { controller.sensorStatus == .streaming }
            if case .unavailable(let reason) = controller.sensorStatus {
                print("SKIP sensor while paused: \(reason)")
            } else {
                check(streaming != nil && idler.status == .paused,
                      String(format: "motion sensor streams while the engine is paused (paused after %.2f s)", t))
            }
        } else {
            check(false, "engine pauses with hit strength on")
        }
        controller.setEnabled(false)
        defaults.removePersistentDomain(forName: AudioRig.isolatedSuite)
    }

    /// Seconds until `condition` held, polling every 10 ms, or nil after `limit`.
    private static func waitUntil(_ limit: Double, _ condition: () -> Bool) async -> Double? {
        let start = MonotonicClock.now()
        while !condition() {
            if MonotonicClock.now() - start > limit { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return MonotonicClock.now() - start
    }

    /// One key press on its own thread, as the tap delivers it.
    private static func press(_ handler: @escaping @Sendable (KeyEvent) -> Void) {
        let thread = Thread {
            let now = MonotonicClock.now()
            handler(KeyEvent(time: now, keyCode: 0, isRelease: false, isModifier: false))
        }
        thread.qualityOfService = .userInteractive
        thread.start()
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

    static func settings() async {
        // Volume 0 and fixed strength: synthetic presses emit at once and stay silent.
        guard let defaults = isolatedDefaults() else { return check(false, "isolated defaults suite") }
        let seed = SettingsStore(defaults: defaults)
        seed.settings.volume = 0
        seed.settings.hitStrengthEnabled = false
        seed.save()
        let login = FakeLoginItem()
        let controller = AppController(defaults: defaults, loginItems: login)
        controller.start()
        let settingsWindow = SettingsWindowController(controller: controller)
        let model = settingsWindow.model
        try? await Task.sleep(for: .milliseconds(300))
        func saved() -> DownstrokeSettings { SettingsStore(defaults: defaults).settings }
        func everywhere<T: Equatable>(_ key: KeyPath<DownstrokeSettings, T>, _ value: T) -> Bool {
            controller.settings[keyPath: key] == value && saved()[keyPath: key] == value && controller.pipeline.settings[keyPath: key] == value
        }

        controller.binding(\.hitStrengthEnabled).wrappedValue = true
        check(everywhere(\.hitStrengthEnabled, true), "hit strength on: saved and in the pipeline")
        controller.binding(\.hitStrengthEnabled).wrappedValue = false
        check(everywhere(\.hitStrengthEnabled, false), "hit strength off: saved and in the pipeline")
        controller.sliderBinding(\.sensitivity).wrappedValue = 0.8
        check(everywhere(\.sensitivity, 0.8), "sensitivity 0.8: saved and in the pipeline")
        controller.binding(\.keyUpSounds).wrappedValue = false
        check(everywhere(\.keyUpSounds, false), "key-up sounds off: saved and in the pipeline")
        controller.sliderBinding(\.stereoWidth).wrappedValue = 0.2
        check(everywhere(\.stereoWidth, 0.2), "stereo width 0.2: saved and in the pipeline")
        controller.binding(\.muteWhileMicInUse).wrappedValue = false
        check(everywhere(\.muteWhileMicInUse, false), "mute while mic in use off: saved and in the pipeline")
        model.mute("com.example.selftest")
        check(everywhere(\.mutedBundleIDs, ["com.example.selftest"]), "muting an app: saved and in the pipeline")
        model.unmuteSelected()
        check(everywhere(\.mutedBundleIDs, []), "unmuting the selected app: saved and in the pipeline")
        let f12 = Hotkey(keyCode: 111, modifiers: Hotkey.control | Hotkey.option | Hotkey.command)
        controller.binding(\.hotkey).wrappedValue = f12
        check(everywhere(\.hotkey, f12) && controller.hotkeys.isRegistered && controller.hotkeyError == nil,
              "hotkey ⌃⌥⌘F12: saved, in the pipeline and registered")
        controller.binding(\.hotkey).wrappedValue = .defaultToggle
        check(everywhere(\.hotkey, .defaultToggle) && controller.hotkeys.isRegistered && controller.hotkeyError == nil,
              "hotkey back to ⌃⌥⌘K: registered (\(controller.hotkeyError ?? "no error"))")

        // Synthetic presses against the frontmost app, before the window activates Downstroke.
        let front = controller.frontmostBundleID ?? "com.example.front"
        if controller.frontmostBundleID == nil { controller.pipeline.setContext(frontmostBundleID: front, micInUse: false) }
        func pressPlays() -> Bool {
            let before = controller.pipeline.lastPress.count
            let now = MonotonicClock.now()
            controller.pipeline.keyEvent(KeyEvent(time: now, keyCode: 0, isRelease: false, isModifier: false), now: now)
            return controller.pipeline.lastPress.count != before
        }
        check(pressPlays(), "synthetic key triggers while \(front) is unmuted")
        model.mute(front)
        check(!pressPlays(), "muting the frontmost app (\(front)) stops the synthetic key's trigger")
        model.unmuteSelected()
        check(pressPlays(), "unmuting \(front) brings the trigger back")
        controller.binding(\.muteWhileMicInUse).wrappedValue = true
        controller.pipeline.setContext(frontmostBundleID: front, micInUse: true)
        check(!pressPlays(), "mic in use with mute-while-mic on: no trigger")
        controller.binding(\.muteWhileMicInUse).wrappedValue = false
        check(pressPlays(), "mic in use with mute-while-mic off: trigger")
        controller.pipeline.setContext(frontmostBundleID: front, micInUse: SystemAudio.micInUse)

        check(controller.settings.enabled && controller.hotkeys.isRegistered, "⌃⌥⌘K registered while on")
        controller.hotkeys.simulatePress()
        check(everywhere(\.enabled, false) && PanelState(controller).status == "Off", "hotkey turns Downstroke off, saved, panel says Off")
        controller.hotkeys.simulatePress()
        check(everywhere(\.enabled, true), "hotkey turns Downstroke back on, saved")

        controller.setHotkeySuspended(true)
        check(!controller.hotkeys.isRegistered, "recording releases the hotkey")
        controller.setHotkeySuspended(false)
        check(controller.hotkeys.isRegistered, "ending recording registers it again")

        controller.binding(\.hotkey).wrappedValue = Hotkey(keyCode: KeyCode.k, modifiers: 0)
        check(!controller.hotkeys.isRegistered && controller.hotkeyError != nil,
              "unusable hotkey shows an error (\(controller.hotkeyError ?? "none"))")
        let status = PanelState.status(
            enabled: true, permissionMissing: false, frontmostBundleID: nil, mutedBundleIDs: [], micInUse: false,
            muteWhileMicInUse: true, boardName: "Holy Panda", hotkeyUnavailable: true, appName: { $0 })
        check(status == "Hotkey unavailable", "panel status: Hotkey unavailable")
        if !controller.permissionMissing && !controller.micInUse {
            check(PanelState(controller).status == "Hotkey unavailable", "live panel status shows the failed hotkey")
        }
        let taken = Hotkey(keyCode: 109, modifiers: Hotkey.control | Hotkey.option | Hotkey.command)
        let squatter = HotkeyCenter()
        let squatStatus = squatter.register(taken) {}
        controller.binding(\.hotkey).wrappedValue = taken
        check(squatStatus == noErr && !controller.hotkeys.isRegistered
              && controller.hotkeyError == "⌃⌥⌘F10 is already in use as a global shortcut.",
              "a combo held by another registration shows in use (\(controller.hotkeyError ?? "no error"))")
        squatter.unregister()
        controller.binding(\.hotkey).wrappedValue = .defaultToggle
        check(controller.hotkeys.isRegistered && controller.hotkeyError == nil, "default hotkey restored and registered")
        let intruder = HotkeyCenter()
        check(intruder.register(.defaultToggle) {} == OSStatus(eventHotKeyExistsErr), "our exclusive ⌃⌥⌘K refuses a second registration")
        intruder.unregister()
        check(controller.hotkeys.isRegistered, "⌃⌥⌘K still registered after the refused duplicate")

        check(!controller.launchesAtLogin && login.registerCalls == 0, "launch at login off by default, nothing registered at start")
        controller.setLaunchAtLogin(true)
        check(login.registerCalls == 1 && controller.loginStatus == .enabled && controller.loginError == nil && everywhere(\.launchAtLogin, true),
              "launch at login on: registered, saved and in the pipeline")
        controller.setLaunchAtLogin(false)
        check(login.unregisterCalls == 1 && !controller.launchesAtLogin && everywhere(\.launchAtLogin, false), "launch at login off: unregistered")
        login.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        controller.setLaunchAtLogin(true)
        check(controller.loginError?.contains("Operation not permitted") == true && !controller.launchesAtLogin && everywhere(\.launchAtLogin, false),
              "failed registration shows its error (\(controller.loginError ?? "none")) and stays off")
        login.failure = nil
        login.status = .requiresApproval
        controller.refreshLoginStatus()
        check(controller.launchesAtLogin, "requires-approval reads as on, with the approval hint")
        login.status = .notRegistered
        controller.refreshLoginStatus()

        controller.openSettings()
        try? await Task.sleep(for: .milliseconds(400))
        guard let window = settingsWindow.window else { return check(false, "Settings window built") }
        check(window.isVisible, "openSettings shows the Settings window")
        if NSApp.isActive {
            check(window.isKeyWindow, "Settings is key and Downstroke active")
        } else {
            // macOS may decline activation for a terminal-launched process; float the window so the visibility checks still run.
            print("SKIP Settings key/active: macOS declined activation for this run (key \(window.isKeyWindow), active false)")
            window.level = .floating
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(300))
        }
        check(window.title == "General", "window titled after the selected tab (\(window.title))")
        let labels = window.toolbar?.items.map(\.label).filter { !$0.isEmpty } ?? []
        check(labels == SettingsTab.allCases.map(\.title), "toolbar tabs: \(labels.joined(separator: ", "))")
        if let screen = window.screen {
            check(screen.visibleFrame.contains(window.frame), "window fits on screen (\(Int(window.frame.width))×\(Int(window.frame.height)))")
        }
        check(!settingsWindow.diagnostics.isActive, "diagnostics idle on the General tab")
        let recorder = model.recorder
        recorder.start()
        check(recorder.recording && recorder.isMonitoring && !controller.hotkeys.isRegistered, "recording suspends the hotkey")
        recorder.handle(keyCode: UInt16(KeyCode.k), flags: .option)
        check(recorder.recording && recorder.problem?.contains("Add ⌃ or ⌘") == true && controller.settings.hotkey == .defaultToggle,
              "⌥K is refused while recording (\(recorder.problem ?? "no problem"))")
        recorder.handle(keyCode: 111, flags: [.control, .option, .command])
        check(!recorder.recording && !recorder.isMonitoring && controller.settings.hotkey == f12 && controller.hotkeys.isRegistered,
              "recording ⌃⌥⌘F12 sets and registers it")
        recorder.start()
        recorder.handle(keyCode: UInt16(kVK_Escape), flags: [])
        check(!recorder.recording && controller.settings.hotkey == f12 && controller.hotkeys.isRegistered, "Escape cancels recording")
        controller.update { $0.hotkey = .defaultToggle }
        recorder.start()
        settingsWindow.show(.sound)
        try? await Task.sleep(for: .milliseconds(200))
        check(!recorder.recording && !recorder.isMonitoring && controller.hotkeys.isRegistered && controller.hotkeyError == nil,
              "switching tabs stops recording and registers the hotkey again")
        settingsWindow.show(.general)
        try? await Task.sleep(for: .milliseconds(300))
        let generalHeight = window.frame.height
        settingsWindow.show(.about)
        try? await Task.sleep(for: .milliseconds(500))
        let aboutHeight = window.frame.height
        settingsWindow.show(.general)
        try? await Task.sleep(for: .milliseconds(500))
        check(aboutHeight != generalHeight && window.frame.height == generalHeight,
              "window resizes per tab and back (General \(Int(generalHeight)), About \(Int(aboutHeight)), General \(Int(window.frame.height)))")
        settingsWindow.show(.diagnostics)
        try? await Task.sleep(for: .milliseconds(1100))
        let ticks = settingsWindow.diagnostics.ticks
        let snap = settingsWindow.diagnostics.snapshot
        check(settingsWindow.diagnostics.isActive && ticks >= 3, "diagnostics refresh while visible (\(ticks) ticks)")
        check(snap.sampleRate > 0 && snap.ioFrames > 0 && snap.device != "None",
              "diagnostics: \(snap.device), \(snap.sampleRateText), \(snap.ioText), sensor \(snap.sensor)")
        check(snap.engine == "Running" && snap.report.contains("Audio engine: Running"), "diagnostics engine row: \(snap.engine)")
        settingsWindow.show(.sound)
        try? await Task.sleep(for: .milliseconds(300))
        let soundTicks = settingsWindow.diagnostics.ticks
        try? await Task.sleep(for: .milliseconds(500))
        check(!settingsWindow.diagnostics.isActive && settingsWindow.diagnostics.ticks == soundTicks, "diagnostics stop on another tab")
        settingsWindow.show(.diagnostics)
        try? await Task.sleep(for: .milliseconds(300))
        postKey(13, characters: "w", flags: .command, window: window)
        try? await Task.sleep(for: .milliseconds(300))
        check(!window.isVisible, "Cmd-W closes Settings")
        let closedTicks = settingsWindow.diagnostics.ticks
        try? await Task.sleep(for: .milliseconds(500))
        check(!settingsWindow.diagnostics.isActive && settingsWindow.diagnostics.ticks == closedTicks, "diagnostics stop once closed")
        controller.openSettings()
        try? await Task.sleep(for: .milliseconds(300))
        check(settingsWindow.window === window && window.isVisible, "reopening reuses the same window")
        settingsWindow.close()
        try? await Task.sleep(for: .milliseconds(200))
        controller.setEnabled(false)
        defaults.removePersistentDomain(forName: AudioRig.isolatedSuite)
    }

    /// Captures each Settings tab in light and dark to build/settings-<tab>-<appearance>.png.
    static func settingsShots() async {
        guard let defaults = isolatedDefaults() else { return check(false, "isolated defaults suite") }
        let seed = SettingsStore(defaults: defaults)
        seed.settings.volume = 0
        seed.settings.mutedBundleIDs = ["com.apple.Safari", "com.apple.Notes", "us.zoom.xos"]
        seed.save()
        let controller = AppController(defaults: defaults, loginItems: FakeLoginItem())
        controller.start()
        let settingsWindow = SettingsWindowController(controller: controller)
        settingsWindow.model.selectedMuted = "com.apple.Notes"
        try? await Task.sleep(for: .milliseconds(500))
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for tab in SettingsTab.allCases {
                settingsWindow.show(tab)
                settingsWindow.window?.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(tab == .diagnostics ? 1500 : 500))
                guard let window = settingsWindow.window else { return check(false, "Settings window built") }
                let file = out.appendingPathComponent("settings-\(tab.rawValue)-\(name).png")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
                try? p.run()
                p.waitUntilExit()
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                check(p.terminationStatus == 0 && size > 0, "captured \(file.path) (\(Int(window.frame.width))×\(Int(window.frame.height)))")
            }
        }
        // Failure states: an unusable hotkey and a refused login item.
        let login = FakeLoginItem()
        login.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let failing = AppController(defaults: defaults, loginItems: login)
        failing.start()
        let failingWindow = SettingsWindowController(controller: failing)
        failing.update { $0.hotkey = Hotkey(keyCode: KeyCode.c, modifiers: Hotkey.command) }
        failing.setLaunchAtLogin(true)
        failingWindow.show(.general)
        failingWindow.window?.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(500))
        if let window = failingWindow.window {
            let file = out.appendingPathComponent("settings-general-errors-dark.png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
            try? p.run()
            p.waitUntilExit()
            check(p.terminationStatus == 0, "captured \(file.path)")
        }
        failingWindow.close()
        failing.setEnabled(false)
        settingsWindow.close()
        controller.setEnabled(false)
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
