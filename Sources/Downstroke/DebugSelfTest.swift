#if DEBUG
import CoreGraphics
import DownstrokeCore
import Foundation

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
