import Darwin
import DownstrokeCore
import Foundation
import Synchronization

nonisolated(unsafe) private var savedTerminal = termios()
nonisolated(unsafe) private var terminalChanged = false

private func restoreTerminal() {
    guard terminalChanged else { return }
    // Drop typed presses so they don't reach the shell after exit.
    tcflush(STDIN_FILENO, TCIFLUSH)
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal)
}

/// `Downstroke --probe`: checks the sensor streams and that hard presses read at least twice as strong as soft ones.
enum ProbeMode {
    static let pressesPerSet = 20
    static let passRatio: Float = 2.0

    static var isRequested: Bool { CommandLine.arguments.contains("--probe") }

    private final class PressQueue: @unchecked Sendable {
        private let times = Mutex<[Double]>([])
        func push(_ t: Double) { times.withLock { $0.append(t) } }
        func drain() -> [Double] { times.withLock { t in defer { t.removeAll() }; return t } }
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let ring = SampleRing(capacity: 4096)
        let sensor = MotionSensor(ring: ring)
        let tap = KeyTap()
        var failed = false
        print("Downstroke probe")

        do {
            try sensor.start()
            let t0 = MonotonicClock.now()
            Thread.sleep(forTimeInterval: 2)
            // Skip the first 0.5 s while the filter settles.
            let from = t0 + 0.5
            let impacts = ring.impacts(from: from, to: .infinity)
            if let latest = ring.latestTime, impacts.count > 1, latest > from {
                let rate = Double(impacts.count - 1) / (latest - from)
                let noise = median(impacts) * 1000
                print(String(format: "sensor: OK, %.1f Hz, noise floor %.2f mg (wake IOReturn %@)",
                             rate, noise, MotionSensor.hex(sensor.lastWakeResult)))
            } else {
                print("sensor: FAILED, opened but delivered no samples in 2 s (wake IOReturn \(MotionSensor.hex(sensor.lastWakeResult)))")
                failed = true
            }
        } catch {
            print("sensor: FAILED, \(error)")
            failed = true
        }

        if !KeyTap.hasPermission {
            if isatty(STDIN_FILENO) != 0 { KeyTap.requestPermission() }
            print("key tap: FAILED, \(KeyTapError.permissionDenied)")
            print("  Grant Input Monitoring to \(Bundle.main.bundlePath) in System Settings > Privacy & Security > Input Monitoring, then re-run.")
            print("  Run straight from a terminal, macOS checks the terminal app's permission instead; grant it there or launch with open.")
            failed = true
        } else {
            do {
                try tap.start()
                print("key tap: OK")
            } catch {
                print("key tap: FAILED, \(error)")
                failed = true
            }
        }

        func finish(_ code: Int32) -> Never {
            tap.stop()
            sensor.stop()
            restoreTerminal()
            exit(code)
        }
        if failed { finish(2) }

        silenceTerminal()
        let queue = PressQueue()
        tap.onEvent = { e in if !e.isRelease && !e.isModifier { queue.push(e.time) } }
        guard let soft = collect("SOFT", queue: queue, ring: ring), let hard = collect("HARD", queue: queue, ring: ring) else {
            print("sensor: FAILED, stopped delivering samples during the presses")
            finish(2)
        }

        let softMedian = median(soft)
        let hardMedian = median(hard)
        let ratio = hardMedian / softMedian
        print(String(format: "soft median %.2f mg", softMedian * 1000))
        print(String(format: "hard median %.2f mg", hardMedian * 1000))
        print(String(format: "ratio %.2f", ratio))
        let pass = ratio >= passRatio
        print(pass ? "PASS" : "FAIL")
        finish(pass ? 0 : 1)
    }

    /// Peak per press; nil if the sensor stops answering.
    private static func collect(_ label: String, queue: PressQueue, ring: SampleRing) -> [Float]? {
        print("Type \(pressesPerSet) \(label) presses (letter keys; they won't echo here).")
        _ = queue.drain()
        var pending: [Double] = []
        var peaks: [Float] = []
        var missed = 0
        while peaks.count < pressesPerSet {
            pending += queue.drain()
            let now = MonotonicClock.now()
            pending.removeAll { t in
                guard peaks.count < pressesPerSet else { return true }
                if let p = ImpactAnalyzer.peak(in: ring, keyTime: t) {
                    peaks.append(p)
                    print(String(format: "\r  %2d/%d  peak %6.2f mg", peaks.count, pressesPerSet, p * 1000), terminator: "")
                    fflush(stdout)
                    return true
                }
                if now - t > 0.25 {
                    missed += 1
                    return true
                }
                return false
            }
            if missed >= pressesPerSet { print(""); return nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        print("")
        return peaks
    }

    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func silenceTerminal() {
        guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &savedTerminal) == 0 else { return }
        var quiet = savedTerminal
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
        terminalChanged = true
        signal(SIGINT) { _ in
            restoreTerminal()
            _exit(130)
        }
    }
}
