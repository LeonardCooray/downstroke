import Darwin
import Testing
@testable import DownstrokeCore

@Test func machTicksRoundTrip() {
    #expect(abs(MonotonicClock.seconds(fromMachTicks: mach_absolute_time()) - MonotonicClock.now()) < 0.001)
    #expect(MonotonicClock.seconds(fromNanoseconds: 1_500_000_000) == 1.5)
}
