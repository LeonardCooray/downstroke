import DownstrokeCore
import Foundation

/// Pauses the engine after `timeout` idle seconds; the next key or audition wakes it.
@MainActor
final class EngineIdler {
    enum Status: Equatable { case running, paused, off }

    nonisolated let gate: EngineIdleGate
    let engine: AudioEngine
    nonisolated private let mixer: VoiceMixer
    /// Wake start attempts.
    private(set) var wakes = 0
    private var lastFailedWake: Double?
    private var markRenders: Int?
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

    /// A failed wake reads as off until a start succeeds.
    var status: Status { engine.isRunning ? .running : engine.isPaused && lastFailedWake == nil ? .paused : .off }

    /// The key tap's handler, shared with the bench: pipeline, then the wake, then the fallback tick.
    nonisolated static func keyHandler(pipeline: TypingPipeline, ticker: PendingTicker,
                                       idler: EngineIdler) -> @Sendable (KeyEvent) -> Void {
        { e in
            if pipeline.keyEvent(e, now: MonotonicClock.now()) { idler.noteActivity(keyTime: e.time) }
            ticker.keyHandled()
        }
    }

    /// Any thread; never blocks. The first key after a pause marks itself unstale and hops a wake to main.
    nonisolated func noteActivity(keyTime: Double) {
        let now = MonotonicClock.now()
        guard gate.noteActivity(now: now) else { return }
        mixer.setWakeMark(keyTime)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { wake(since: now) }
        }
    }

    /// Main thread, for every start except a wake; counts as activity.
    func start() throws {
        _ = gate.noteActivity(now: MonotonicClock.now())
        gate.unpark()
        try engine.start()
        lastFailedWake = nil
    }

    func stop() {
        gate.unpark()
        engine.stop()
        lastFailedWake = nil
        clearWakeMark()
    }

    /// Main thread, on a timer while Downstroke is on.
    func tick(now: Double) {
        guard engine.isRunning else {
            // Stopped without idling (a failed start or rebuild): no wake is in flight to keep the mark for.
            if !engine.isPaused, mixer.hasWakeMark { clearWakeMark() }
            return
        }
        if mixer.hasWakeMark {
            // Two renders after seeing it running, the waking key has been popped.
            let renders = engine.stats.renders.load(ordering: .relaxed)
            if let marked = markRenders, renders - marked >= 2 { clearWakeMark() } else if markRenders == nil { markRenders = renders }
        }
        guard gate.shouldPause(now: now, activeVoices: mixer.activeVoices), gate.park(now: now) else { return }
        engine.pause()
    }

    private func clearWakeMark() {
        mixer.clearWakeMark()
        markRenders = nil
    }

    private func wake(since: Double) {
        // Stopped or restarted since the activity claimed the wake.
        guard engine.isPaused else { return }
        let t0 = MonotonicClock.now()
        // At most one start attempt a second after a failure.
        if let failed = lastFailedWake, t0 - failed < 1 { return giveUp() }
        wakes += 1
        do {
            try engine.start()
            lastFailedWake = nil
            lastWake = (t0 - since, MonotonicClock.now() - t0)
            onWake?(nil)
        } catch {
            engine.pause()
            lastFailedWake = MonotonicClock.now()
            giveUp()
            onWake?(error)
        }
    }

    // Unplayed keys go back under the stale guard, so a later start never replays them.
    private func giveUp() {
        clearWakeMark()
        gate.repark()
    }
}
