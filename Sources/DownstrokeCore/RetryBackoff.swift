/// Retry delays doubling from `initial` up to `cap`.
public struct RetryBackoff: Sendable {
    public let initial: Double
    public let cap: Double
    public private(set) var failures = 0
    private var nextAttempt = -Double.infinity

    public init(initial: Double, cap: Double) {
        self.initial = initial
        self.cap = cap
    }

    /// Wait after the latest failure; 0 before any.
    public var delay: Double {
        guard failures > 0 else { return 0 }
        // Past 2^60 the doubling only overflows; the cap has long applied.
        return min(initial * Double(UInt64(1) << UInt64(min(failures - 1, 60))), cap)
    }

    /// True after `stop()`, until `reset()`.
    public var isStopped: Bool { nextAttempt == .infinity }

    public func isDue(now: Double) -> Bool { now >= nextAttempt }

    public mutating func failed(now: Double) {
        guard !isStopped else { return }
        failures += 1
        nextAttempt = now + delay
    }

    public mutating func reset() {
        failures = 0
        nextAttempt = -.infinity
    }

    /// No more attempts until `reset()`.
    public mutating func stop() { nextAttempt = .infinity }
}
