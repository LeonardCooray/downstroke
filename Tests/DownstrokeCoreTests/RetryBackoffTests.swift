@testable import DownstrokeCore
import Testing

@Test func firstAttemptIsDueAtOnce() {
    let backoff = RetryBackoff(initial: 0.25, cap: 10)
    #expect(backoff.isDue(now: 0))
    #expect(backoff.failures == 0)
}

@Test func delaysDoubleUpToTheCap() {
    var backoff = RetryBackoff(initial: 0.25, cap: 10)
    var delays: [Double] = []
    for _ in 0..<8 {
        backoff.failed(now: 100)
        delays.append(backoff.delay)
    }
    #expect(delays == [0.25, 0.5, 1, 2, 4, 8, 10, 10])
}

@Test func notDueUntilTheDelayHasPassed() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    backoff.failed(now: 10)
    backoff.failed(now: 11)
    #expect(!backoff.isDue(now: 12.9))
    #expect(backoff.isDue(now: 13))
}

@Test func resetMakesTheNextAttemptDueAtOnce() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    for t in 0..<5 { backoff.failed(now: Double(t)) }
    backoff.reset()
    #expect(backoff.isDue(now: 5))
    backoff.failed(now: 5)
    #expect(backoff.delay == 1)
}

@Test func stopHoldsOffUntilReset() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    backoff.stop()
    #expect(!backoff.isDue(now: 1e9))
    #expect(backoff.isStopped)
    backoff.reset()
    #expect(backoff.isDue(now: 0) && !backoff.isStopped)
}

@Test func manyFailuresStayAtTheCap() {
    var backoff = RetryBackoff(initial: 0.25, cap: 10)
    for _ in 0..<5000 { backoff.failed(now: 0) }
    #expect(backoff.delay == 10)
    #expect(backoff.isDue(now: 10) && !backoff.isDue(now: 9.99))
}

@Test func aNewKindOfFailureStartsFromTheInitialDelay() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    for t in 0..<7 { backoff.failed(now: Double(t), kind: 1) }
    #expect(backoff.delay == 60)
    backoff.failed(now: 100, kind: 2)
    #expect(backoff.failures == 1 && backoff.delay == 1)
    #expect(backoff.isDue(now: 101))
}

@Test func limitStopsAfterThatManyFailuresOfOneKind() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    backoff.failed(now: 0, kind: 1)
    backoff.failed(now: 1, kind: 1)
    for t in 2..<5 { backoff.failed(now: Double(t), kind: 2, limit: 4) }
    #expect(!backoff.isStopped)
    backoff.failed(now: 5, kind: 2, limit: 4)
    #expect(backoff.isStopped)
    backoff.reset()
    backoff.failed(now: 6, kind: 2, limit: 4)
    #expect(!backoff.isStopped && backoff.failures == 1)
}

@Test func alternatingKindsStillBackOffAndReachTheLimit() {
    var backoff = RetryBackoff(initial: 1, cap: 60)
    var delays: [Double] = []
    for i in 0..<7 {
        backoff.failed(now: Double(i), kind: i % 2, limit: 4)
        delays.append(backoff.delay)
    }
    #expect(delays == [1, 1, 2, 2, 4, 4, 8])
    #expect(backoff.isStopped)
}
