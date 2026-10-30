import Synchronization

/// Key events plus sensor data in, triggers for the mixer out.
public final class TypingPipeline: @unchecked Sendable {
    // How long after a press its hit window is complete, and when to give up waiting for it.
    private static let windowDelay = 0.008
    private static let flushDelay = 0.012
    private static let fixedVelocity: Float = 0.5

    private struct State {
        var settings = DownstrokeSettings()
        var bank: SampleBank?
        var sensorAvailable = false
        var frontmostBundleID: String?
        var micInUse = false
        var planner: TriggerPlanner
        // Events waiting for the oldest press's hit window, in arrival order.
        var pending: [KeyEvent] = []
    }

    private let queue: TriggerQueue
    private let ring: SampleRing?
    private let state: Mutex<State>

    public init(queue: TriggerQueue, ring: SampleRing?, random: sending any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.queue = queue
        self.ring = ring
        state = Mutex(State(planner: TriggerPlanner(random: random)))
    }

    /// Main thread.
    public func update(settings: DownstrokeSettings, bank: SampleBank, sensorAvailable: Bool) {
        state.withLock { s in
            s.settings = settings
            s.bank = bank
            s.sensorAvailable = sensorAvailable
            if !sensing(s) { flushAll(&s) }
        }
    }

    /// Main thread.
    public func setContext(frontmostBundleID: String?, micInUse: Bool) {
        state.withLock { s in
            s.frontmostBundleID = frontmostBundleID
            s.micInUse = micInUse
        }
    }

    /// Key tap thread.
    public func keyEvent(_ e: KeyEvent, now: Double) {
        state.withLock { s in
            guard s.bank != nil, MuteRules.shouldPlay(
                enabled: s.settings.enabled, frontmostBundleID: s.frontmostBundleID,
                muted: s.settings.mutedBundleIDs, micInUse: s.micInUse,
                muteWhileMicInUse: s.settings.muteWhileMicInUse)
            else { return }
            if !sensing(s) {
                emit(e, velocity: Self.fixedVelocity, &s)
            } else if e.isRelease && s.pending.isEmpty {
                emit(e, velocity: Self.fixedVelocity, &s)
            } else {
                s.pending.append(e)
                resolve(now: now, &s)
            }
        }
    }

    /// Sensor thread after each sample, and a 1 ms fallback timer.
    public func tick(now: Double) {
        state.withLock { s in
            guard !s.pending.isEmpty else { return }
            resolve(now: now, &s)
        }
    }

    /// Plays a fixed A-key press, ignoring `enabled` and the mute rules.
    public func audition(boardBank: SampleBank) {
        state.withLock { s in
            var settings = s.settings
            settings.stereoWidth = 0
            let e = KeyEvent(time: MonotonicClock.now(), keyCode: 0, isRelease: false, isModifier: false)
            for t in s.planner.plan(e, velocity: 0.625, bank: boardBank, settings: settings) { _ = queue.push(t) }
        }
    }

    private func sensing(_ s: State) -> Bool {
        s.settings.hitStrengthEnabled && s.sensorAvailable && ring != nil
    }

    // Plans queued events from the front until one is still waiting for its window.
    private func resolve(now: Double, _ s: inout State) {
        while let e = s.pending.first {
            if e.isRelease {
                s.pending.removeFirst()
                emit(e, velocity: Self.fixedVelocity, &s)
                continue
            }
            guard now >= e.time + Self.windowDelay else { return }
            var velocity: Float?
            if let ring, let peak = ImpactAnalyzer.peak(in: ring, keyTime: e.time) {
                velocity = VelocityMapper(sensitivity: s.settings.sensitivity).velocity(forPeak: peak) ?? Self.fixedVelocity
            } else if now >= e.time + Self.flushDelay {
                velocity = Self.fixedVelocity
            }
            guard let velocity else { return }
            s.pending.removeFirst()
            emit(e, velocity: velocity, &s)
        }
    }

    private func flushAll(_ s: inout State) {
        let events = s.pending
        s.pending.removeAll()
        for e in events { emit(e, velocity: Self.fixedVelocity, &s) }
    }

    private func emit(_ e: KeyEvent, velocity: Float, _ s: inout State) {
        guard let bank = s.bank else { return }
        for t in s.planner.plan(e, velocity: velocity, bank: bank, settings: s.settings) { _ = queue.push(t) }
    }
}
