/// Retry delays doubling from `initial` up to `cap`, counted per kind of failure since the last `reset()`.
public struct RetryBackoff: Sendable {
    public let initial: Double
    public let cap: Double
    /// Failures of the latest kind since the last reset.
    public private(set) var failures = 0
    private var nextAttempt = -Double.infinity
    private var counts: [Int: Int] = [:]

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

    /// `limit`: stop once this many failures of `kind` have come since the last reset.
    public mutating func failed(now: Double, kind: Int = 0, limit: Int? = nil) {
        guard !isStopped else { return }
        failures = counts[kind, default: 0] + 1
        counts[kind] = failures
        nextAttempt = now + delay
        if let limit, failures >= limit { stop() }
    }

    public mutating func reset() {
        failures = 0
        counts = [:]
        nextAttempt = -.infinity
    }

    /// No more attempts until `reset()`.
    public mutating func stop() { nextAttempt = .infinity }
}
