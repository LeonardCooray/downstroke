#if DEBUG
import CoreGraphics
import DownstrokeCore
import Foundation

// Debug-only checks: `Downstroke --self-test <name>` prints PASS/FAIL lines and exits non-zero on any FAIL.
@MainActor
enum DebugSelfTest {
    private static var failures = 0

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count else { return }
        Task { @MainActor in
            switch args[i + 1] {
            case "tap-reenable": tapReenable()
            case "sensor-restart": await sensorRestart()
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
}
#endif
