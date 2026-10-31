import Synchronization

/// Key events plus sensor data in, triggers for the mixer out.
public final class TypingPipeline: @unchecked Sendable {
    // How long after a press its hit window is complete, and when to give up waiting for it.
    private static let windowDelay = 0.008
    private static let flushDelay = 0.012
    private static let fixedVelocity = SlamMapper.normalVelocity

    private struct State {
        var settings = DownstrokeSettings()
        var bank: SampleBank?
        var sensorAvailable = false
        var frontmostBundleID: String?
        var micInUse = false
        var planner: TriggerPlanner
        // Events waiting for the oldest press's hit window, in arrival order.
        var pending: [KeyEvent] = []
        var lastVelocity: Float?
    }

    private let queue: TriggerQueue
    private let ring: SampleRing?
    private let state: Mutex<State>
    // Mirrors `!pending.isEmpty`, written under the lock, so idle ticks skip it.
    private let pendingFlag = Atomic<Bool>(false)
    // Press count in the high 32 bits, meter level bit pattern in the low 32.
    private let pressStamp = Atomic<UInt64>(0)
    private let slams = Atomic<Int>(0)

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
            publishPending(s)
        }
    }

    /// Main thread.
    public func setContext(frontmostBundleID: String?, micInUse: Bool) {
        state.withLock { s in
            s.frontmostBundleID = frontmostBundleID
            s.micInUse = micInUse
        }
    }

    /// Key tap thread. False when the event was dropped (off, muted or no bank yet).
    @discardableResult
    public func keyEvent(_ e: KeyEvent, now: Double) -> Bool {
        state.withLock { s in
            guard s.bank != nil, MuteRules.shouldPlay(
                enabled: s.settings.enabled, frontmostBundleID: s.frontmostBundleID,
                muted: s.settings.mutedBundleIDs, micInUse: s.micInUse,
                muteWhileMicInUse: s.settings.muteWhileMicInUse)
            else { return false }
            if !sensing(s) {
                emit(e, velocity: Self.fixedVelocity, &s)
            } else if e.isRelease && s.pending.isEmpty {
                emit(e, velocity: Self.fixedVelocity, &s)
            } else {
                s.pending.append(e)
                resolve(now: now, &s)
                publishPending(s)
            }
            return true
        }
    }

    /// Sensor thread after each sample, and a 1 ms fallback timer.
    public func tick(now: Double) {
        guard pendingFlag.load(ordering: .acquiring) else { return }
        state.withLock { s in
            guard !s.pending.isEmpty else { return }
            resolve(now: now, &s)
            publishPending(s)
        }
    }

    /// The settings from the latest `update`.
    public var settings: DownstrokeSettings { state.withLock { $0.settings } }

    /// True while a press waits for its hit window; drives the fallback tick timer.
    public var hasPending: Bool { pendingFlag.load(ordering: .acquiring) }

    /// Velocity of the latest played press, nil before the first.
    public var lastVelocity: Float? { state.withLock { $0.lastVelocity } }

    /// Lock-free count and meter level of played presses; a new count means a new press, level 0.5 is the slam threshold.
    public var lastPress: (count: UInt32, level: Float) {
        let stamp = pressStamp.load(ordering: .acquiring)
        return (UInt32(truncatingIfNeeded: stamp >> 32), Float(bitPattern: UInt32(truncatingIfNeeded: stamp)))
    }

    /// Presses played heavier than normal since launch.
    public var slamCount: Int { slams.load(ordering: .relaxed) }

    /// Plays a fixed A-key press, ignoring `enabled` and the mute rules.
    public func audition(boardBank: SampleBank) {
        state.withLock { s in
            var settings = s.settings
            settings.stereoWidth = 0
            let e = KeyEvent(time: MonotonicClock.now(), keyCode: 0, isRelease: false, isModifier: false)
            for t in s.planner.plan(e, velocity: 0.625, bank: boardBank, settings: settings) { _ = queue.push(t) }
        }
    }

    private func publishPending(_ s: State) {
        pendingFlag.store(!s.pending.isEmpty, ordering: .releasing)
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
            var hit: (velocity: Float, level: Float)?
            if let ring, let peak = ImpactAnalyzer.peak(in: ring, keyTime: e.time) {
                let mapper = SlamMapper(sensitivity: s.settings.sensitivity)
                hit = (mapper.velocity(forPeak: peak), mapper.meterLevel(forPeak: peak))
            } else if now >= e.time + Self.flushDelay {
                hit = (Self.fixedVelocity, 0)
            }
            guard let hit else { return }
            s.pending.removeFirst()
            emit(e, velocity: hit.velocity, level: hit.level, &s)
        }
    }

    private func flushAll(_ s: inout State) {
        let events = s.pending
        s.pending.removeAll()
        for e in events { emit(e, velocity: Self.fixedVelocity, &s) }
    }

    private func emit(_ e: KeyEvent, velocity: Float, level: Float = 0, _ s: inout State) {
        guard let bank = s.bank else { return }
        if !e.isRelease {
            s.lastVelocity = velocity
            if velocity > Self.fixedVelocity { slams.add(1, ordering: .relaxed) }
            let count = (pressStamp.load(ordering: .relaxed) >> 32) &+ 1
            pressStamp.store(count << 32 | UInt64(level.bitPattern), ordering: .releasing)
        }
        for t in s.planner.plan(e, velocity: velocity, bank: bank, settings: s.settings) { _ = queue.push(t) }
    }
}
