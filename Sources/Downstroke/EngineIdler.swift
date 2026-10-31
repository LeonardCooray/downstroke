import DownstrokeCore
import Foundation

/// Pauses the engine after `timeout` seconds with no key, audition or sounding voice, and wakes it on the next one.
@MainActor
final class EngineIdler {
    enum Status: Equatable { case running, paused, off }

    nonisolated let gate: EngineIdleGate
    let engine: AudioEngine
    private let mixer: VoiceMixer
    private(set) var wakes = 0
    /// Seconds from the waking activity to the main thread taking it, and the engine start that followed.
    private(set) var lastWake: (hop: Double, start: Double)?
    /// Main thread, after each wake's start attempt.
    var onWake: ((_ error: (any Error)?) -> Void)?

    init(engine: AudioEngine, mixer: VoiceMixer, timeout: Double) {
        self.engine = engine
        self.mixer = mixer
        gate = EngineIdleGate(timeout: timeout, now: MonotonicClock.now())
    }

    var timeout: Double {
        get { gate.timeout }
        set { gate.timeout = newValue }
    }

    var status: Status { engine.isRunning ? .running : engine.isPaused ? .paused : .off }

    /// The key tap's handler, shared with the bench: pipeline, then the wake, then the fallback tick.
    nonisolated static func keyHandler(pipeline: TypingPipeline, ticker: PendingTicker,
                                       idler: EngineIdler) -> @Sendable (KeyEvent) -> Void {
        { e in
            if pipeline.keyEvent(e, now: MonotonicClock.now()) { idler.noteActivity() }
            ticker.keyHandled()
        }
    }

    /// Any thread; never blocks. The first activity after a pause hops a wake to main.
    nonisolated func noteActivity() {
        let now = MonotonicClock.now()
        guard gate.noteActivity(now: now) else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { wake(since: now) }
        }
    }

    /// Main thread, for every start except a wake; counts as activity.
    func start() throws {
        _ = gate.noteActivity(now: MonotonicClock.now())
        gate.unpark()
        try engine.start()
    }

    func stop() {
        gate.unpark()
        engine.stop()
    }

    /// Main thread, on a timer while Downstroke is on.
    func tick(now: Double) {
        guard engine.isRunning, gate.shouldPause(now: now, activeVoices: mixer.activeVoices), gate.park(now: now) else { return }
        engine.pause()
    }

    private func wake(since: Double) {
        // Stopped or restarted since the activity claimed the wake.
        guard engine.isPaused else { return }
        wakes += 1
        let t0 = MonotonicClock.now()
        do {
            try engine.start()
            lastWake = (t0 - since, MonotonicClock.now() - t0)
            onWake?(nil)
        } catch {
            engine.pause()
            gate.repark()
            onWake?(error)
        }
    }
}
