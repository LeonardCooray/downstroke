import Darwin
import DownstrokeCore
import Foundation
import Synchronization

struct MissingBoard: Error, CustomStringConvertible {
    var id: String
    var description: String { "no bundled board \(id)" }
}

/// The real engine, mixer and pipeline without the tap or sensor, for `--bench` and the audio self-tests.
@MainActor
final class AudioRig {
    static let isolatedSuite = "com.leonardcooray.downstroke.selftest"

    let queue = TriggerQueue()
    let ring = SampleRing()
    let mixer: VoiceMixer
    let engine: AudioEngine
    let pipeline: TypingPipeline
    let ticker: PendingTicker
    let boards: [Board]
    /// Defaults read from the isolated suite, never the app's own domain.
    let settings: DownstrokeSettings

    init() {
        mixer = VoiceMixer(queue: queue)
        engine = AudioEngine(mixer: mixer)
        pipeline = TypingPipeline(queue: queue, ring: ring)
        ticker = PendingTicker(pipeline: pipeline)
        boards = BundledPacks.load().0
        settings = SettingsStore(defaults: UserDefaults(suiteName: Self.isolatedSuite)!).settings
        pipeline.setContext(frontmostBundleID: nil, micInUse: false)
    }

    func bank(_ id: String) throws -> SampleBank {
        guard let board = boards.first(where: { $0.id == id }) else { throw MissingBoard(id: id) }
        return try SampleBank(board: board, sampleRate: engine.sampleRate)
    }

    func drainLatencies() -> [Double] {
        var values: [Double] = []
        mixer.drainLatencies(into: &values)
        return values
    }
}

/// Feeds the ring at 800 Hz from its own thread and ticks the pipeline after each sample, like MotionSensor.
final class SyntheticSensor: @unchecked Sendable {
    private let ring: SampleRing
    private let pipeline: TypingPipeline
    private let stopRequested = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    let lastPressBits = Atomic<UInt64>(0)

    init(ring: SampleRing, pipeline: TypingPipeline) {
        self.ring = ring
        self.pipeline = pipeline
    }

    func start() {
        let thread = Thread { [self] in
            var next = MonotonicClock.now()
            while !stopRequested.load(ordering: .relaxed) {
                next += 1.0 / 800
                BenchMode.sleep(until: next)
                let now = MonotonicClock.now()
                let sincePress = now - Double(bitPattern: lastPressBits.load(ordering: .relaxed))
                ring.append(time: now, impact: sincePress >= 0 && sincePress < 0.004 ? 0.05 : 0.001)
                pipeline.tick(now: now)
            }
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stopRequested.store(true, ordering: .relaxed)
        finished.wait()
    }
}

/// `Downstroke --bench`: measures the spec's speed budgets on the real engine and pipeline.
@MainActor
enum BenchMode {
    nonisolated static let keysPerSecond = 15.0
    nonisolated static let seconds = 10.0
    nonisolated static let holdTime = 0.04
    // Letters, space and return; modifiers don't change the cost.
    nonisolated static let keyCodes: [UInt16] = [17, 4, 14, 49, 12, 32, 34, 8, 40, 49, 11, 15, 31, 13, 45, 49, 3, 31, 7, 36]

    static var isRequested: Bool { CommandLine.arguments.contains("--bench") }

    private static var failures = 0

    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Downstroke bench")
        let rig = AudioRig()
        var settings = rig.settings
        settings.enabled = true

        let loadStart = MonotonicClock.now()
        var banks: [SampleBank] = []
        for board in rig.boards {
            do { banks.append(try rig.bank(board.id)) } catch { print("bank \(board.id) failed: \(error)") }
        }
        let bankBytes = banks.reduce(0) { $0 + $1.byteCount }
        print(String(format: "banks: %d loaded in %.2f s, %.1f MB of PCM", banks.count,
                     MonotonicClock.now() - loadStart, Double(bankBytes) / 1e6))
        guard let bank = banks.first(where: { $0.boardID == settings.boardID }) ?? banks.first else {
            check(false, "board banks load")
            return 1
        }

        do { try rig.engine.start() } catch {
            check(false, "engine starts (\(error))")
            return 1
        }
        rig.mixer.setMasterGain(settings.volume)
        try? await Task.sleep(for: .milliseconds(500))
        let rate = rig.engine.sampleRate, frames = rig.engine.ioBufferFrames
        let buffer = Double(frames) / rate
        let lead = rig.engine.stats.lead
        print(String(format: "engine: %.0f Hz, I/O buffer %d frames (%.2f ms), render lead %.2f ms (output host time minus render start)",
                     rate, frames, buffer * 1000, lead * 1000))
        if let hw = SystemAudio.outputHardwareLatencyFrames {
            print(String(format: "output device: safety offset %d + latency %d frames = %.2f ms; lead minus buffer %.2f ms",
                         hw.safety, hw.latency, Double(hw.safety + hw.latency) / rate * 1000, (lead - buffer) * 1000))
        }
        guard rig.engine.stats.renders.load(ordering: .relaxed) > 0 else {
            check(false, "no render callbacks in 500 ms (run from a foreground session with audio access)")
            return 1
        }
        var footprint = physFootprint()
        let renders0 = rig.engine.stats.renders.load(ordering: .relaxed)
        let overruns0 = rig.engine.stats.overruns.load(ordering: .relaxed)

        settings.hitStrengthEnabled = false
        rig.pipeline.update(settings: settings, bank: bank, sensorAvailable: false)
        let idle = await cpuPercent { try? await Task.sleep(for: .seconds(seconds)) }

        let syntheticIdle: Double
        do {
            let sensor = SyntheticSensor(ring: rig.ring, pipeline: rig.pipeline)
            sensor.start()
            syntheticIdle = await cpuPercent { try? await Task.sleep(for: .seconds(seconds)) }
            sensor.stop()
        }

        // The real MotionSensor, wired as AppController wires it; it needs no Input Monitoring.
        var realIdle: Double?, realSensorOnly: Double?, realRate = 0.0, realError: String?
        do {
            settings.hitStrengthEnabled = true
            rig.pipeline.update(settings: settings, bank: bank, sensorAvailable: true)
            let sensor = MotionSensor(ring: rig.ring)
            let pipeline = rig.pipeline
            let samples = Atomic<Int>(0)
            sensor.onSample = { _ in
                samples.add(1, ordering: .relaxed)
                pipeline.tick(now: MonotonicClock.now())
            }
            do {
                try sensor.start()
                try? await Task.sleep(for: .seconds(1))
                let n0 = samples.load(ordering: .relaxed), t0 = MonotonicClock.now()
                realIdle = await cpuPercent { try? await Task.sleep(for: .seconds(seconds)) }
                realRate = Double(samples.load(ordering: .relaxed) - n0) / (MonotonicClock.now() - t0)
                rig.engine.stop()
                try? await Task.sleep(for: .milliseconds(300))
                realSensorOnly = await cpuPercent { try? await Task.sleep(for: .seconds(seconds)) }
                sensor.stop()
                try rig.engine.start()
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                realError = "\(error)"
                sensor.stop()
                if !rig.engine.isRunning { try? rig.engine.start() }
            }
            settings.hitStrengthEnabled = false
            rig.pipeline.update(settings: settings, bank: bank, sensorAvailable: false)
        }

        _ = rig.drainLatencies()
        let off = await typing(rig, settings: settings, bank: bank, sensor: nil)

        settings.hitStrengthEnabled = true
        let sensor = SyntheticSensor(ring: rig.ring, pipeline: rig.pipeline)
        sensor.start()
        try? await Task.sleep(for: .milliseconds(100))
        rig.pipeline.update(settings: settings, bank: bank, sensorAvailable: true)
        let on = await typing(rig, settings: settings, bank: bank, sensor: sensor)
        sensor.stop()

        footprint = max(footprint, physFootprint())
        let renders = rig.engine.stats.renders.load(ordering: .relaxed) - renders0
        let overruns = rig.engine.stats.overruns.load(ordering: .relaxed) - overruns0
        rig.engine.stop()

        // Ruling: judged to the start of the render cycle that first renders the sound.
        let minLead = rig.engine.stats.minLead
        print(String(format: "render-cycle start = output host time minus the smallest render lead seen (%.2f ms)", minLead * 1000))
        let offRender = off.latencies.map { $0 - minLead }, onRender = on.latencies.map { $0 - minLead }
        latencyLine("latency p99, key event to render-cycle start, hit strength off", offRender, budget: 0.003 + buffer)
        latencyLine("latency p99, key event to render-cycle start, hit strength on", onRender, budget: 0.008 + 0.003 + buffer)
        info("key event to output time (what you hear, as the live readout), hit strength off", off.latencies)
        info("key event to output time (what you hear, as the live readout), hit strength on", on.latencies)
        print("info stale triggers dropped: \(rig.mixer.staleTriggers) (latency samples are key presses only, one per press)")
        cpuLine("idle CPU, engine running (hit strength off)", idle, budget: 1.0)
        print(String(format: "info idle CPU, engine + synthetic 800 Hz sensor: %.2f%% of a core (not checked)", syntheticIdle))
        if let realIdle, let realSensorOnly, realRate >= 700 {
            // Ruling: hit strength on has its own idle budget, set from the measured HID floor.
            cpuLine(String(format: "idle CPU, engine + real sensor (%.0f Hz), hit-strength-on idle budget", realRate), realIdle, budget: 1.5)
            print(String(format: "info idle CPU, real sensor only, engine stopped: %.2f%% of a core (not checked)", realSensorOnly))
        } else {
            let reason = realError ?? String(format: "sensor delivered %.0f Hz, below 700 Hz", realRate)
            print("SKIP idle CPU, engine + real sensor: \(reason); the hit-strength-on idle budget (1.5%) was not checked")
        }
        cpuLine("typing CPU, hit strength off", off.cpu, budget: 3.0)
        cpuLine("typing CPU, hit strength on (synthetic sensor)", on.cpu, budget: 3.0)
        let mb = Double(footprint) / 1_048_576
        check(footprint > 0 && mb <= 100 && !rig.boards.isEmpty && banks.count == rig.boards.count,
              String(format: "phys_footprint %.1f MB with %d of %d banks loaded (budget 100 MB, all banks)", mb, banks.count, rig.boards.count))
        check(renders > 0 && overruns == 0, String(format: "render overruns %d in %d renders (worst %.3f ms, limit %.3f ms)",
                                                   overruns, renders, rig.engine.stats.worstRender * 1000, buffer / 2 * 1000))
        print(failures == 0 ? "PASS" : "FAIL")
        return failures == 0 ? 0 : 1
    }

    private struct Run {
        var latencies: [Double]
        var cpu: Double
    }

    private static func typing(_ rig: AudioRig, settings: DownstrokeSettings, bank: SampleBank, sensor: SyntheticSensor?) async -> Run {
        _ = rig.drainLatencies()
        let pipeline = rig.pipeline, ticker = rig.ticker
        let cpu = await cpuPercent {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let thread = Thread {
                    feedKeys(pipeline: pipeline, ticker: ticker, sensor: sensor)
                    done.resume()
                }
                thread.qualityOfService = .userInteractive
                thread.start()
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        return Run(latencies: rig.drainLatencies(), cpu: cpu)
    }

    // Runs on its own thread, as the key tap does.
    private nonisolated static func feedKeys(pipeline: TypingPipeline, ticker: PendingTicker, sensor: SyntheticSensor?) {
        let start = MonotonicClock.now() + 0.05
        let count = Int(keysPerSecond * seconds)
        var events: [(at: Double, index: Int, release: Bool)] = []
        for i in 0..<count {
            // Jitter: 1/15 s is exactly 25 I/O cycles, so an even beat would sample one render phase.
            let at = start + Double(i) / keysPerSecond + Double.random(in: -0.01...0.01)
            events.append((at, i, false))
            events.append((at + holdTime, i, true))
        }
        events.sort { $0.at < $1.at }
        for event in events {
            sleep(until: event.at)
            let now = MonotonicClock.now()
            if !event.release { sensor?.lastPressBits.store(now.bitPattern, ordering: .relaxed) }
            let code = keyCodes[event.index % keyCodes.count]
            pipeline.keyEvent(KeyEvent(time: now, keyCode: code, isRelease: event.release, isModifier: false), now: now)
            ticker.keyHandled()
        }
    }

    nonisolated static func sleep(until time: Double) {
        let wait = time - MonotonicClock.now()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    private static func cpuPercent(_ body: () async -> Void) async -> Double {
        let cpu0 = cpuSeconds(), wall0 = MonotonicClock.now()
        await body()
        return (cpuSeconds() - cpu0) / (MonotonicClock.now() - wall0) * 100
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    private static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // Nearest rank, as LatencyStats.
    private static func rank(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(max(Int((p * Double(sorted.count) - 1e-9).rounded(.up)), 1), sorted.count) - 1]
    }

    private static func latencyLine(_ name: String, _ values: [Double], budget: Double) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return check(false, "\(name): no latency samples") }
        let p99 = rank(sorted, 0.99)
        check(p99 <= budget, String(format: "%@ %.2f ms (budget %.2f ms; p50 %.2f ms, max %.2f ms, n=%d)",
                                    name, p99 * 1000, budget * 1000, rank(sorted, 0.5) * 1000, sorted.last! * 1000, sorted.count))
    }

    private static func info(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return print("info \(name): no samples") }
        print(String(format: "info %@: p99 %.2f ms, p50 %.2f ms, max %.2f ms, n=%d (not checked)",
                     name, rank(sorted, 0.99) * 1000, rank(sorted, 0.5) * 1000, sorted.last! * 1000, sorted.count))
    }

    private static func cpuLine(_ name: String, _ percent: Double, budget: Double) {
        check(percent <= budget, String(format: "%@ %.2f%% of a core (budget %.1f%%)", name, percent, budget))
    }

    private static func check(_ ok: Bool, _ line: String) {
        if !ok { failures += 1 }
        print(ok ? "PASS \(line)" : "FAIL \(line)")
    }
}
