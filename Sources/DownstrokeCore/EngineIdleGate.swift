import Synchronization

/// When the audio engine may pause for idleness, and exactly one wake per pause; any thread unless noted.
// Activity stores its stamp then reads `parked`; parking stores `parked` then reads the stamp, so one side always sees the other.
public final class EngineIdleGate: Sendable {
    private let lastActivityBits: Atomic<UInt64>
    private let timeoutBits: Atomic<UInt64>
    private let parked = Atomic<Bool>(false)

    public init(timeout: Double, now: Double) {
        lastActivityBits = Atomic(now.bitPattern)
        timeoutBits = Atomic(timeout.bitPattern)
    }

    /// Seconds without activity before a pause; zero, negative or NaN never pauses.
    public var timeout: Double {
        get { Double(bitPattern: timeoutBits.load(ordering: .relaxed)) }
        set { timeoutBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    public var lastActivity: Double { Double(bitPattern: lastActivityBits.load(ordering: .sequentiallyConsistent)) }

    public var isParked: Bool { parked.load(ordering: .sequentiallyConsistent) }

    /// Records activity; true when the engine was parked and this caller must wake it.
    public func noteActivity(now: Double) -> Bool {
        lastActivityBits.store(now.bitPattern, ordering: .sequentiallyConsistent)
        return parked.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged
    }

    /// Main thread. Idle past the timeout with nothing sounding, and not already parked.
    public func shouldPause(now: Double, activeVoices: Int) -> Bool {
        let timeout = timeout
        guard timeout > 0, !isParked, activeVoices == 0 else { return false }
        return now - lastActivity >= timeout
    }

    /// Main thread, just before pausing. False when activity arrived since the decision, so don't pause.
    public func park(now: Double) -> Bool {
        parked.store(true, ordering: .sequentiallyConsistent)
        let timeout = timeout
        if timeout > 0, now - lastActivity >= timeout { return true }
        // A failed exchange means a waker already claimed it; its wake finds the engine running.
        _ = parked.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent)
        return false
    }

    /// Main thread, whenever the engine starts for any reason.
    public func unpark() { parked.store(false, ordering: .sequentiallyConsistent) }

    /// Main thread, after a wake failed to start the engine, so the next activity retries.
    public func repark() { parked.store(true, ordering: .sequentiallyConsistent) }
}
