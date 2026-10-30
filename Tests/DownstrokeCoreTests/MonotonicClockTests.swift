import Darwin
import Testing
@testable import DownstrokeCore

@Test func machTicksRoundTrip() {
    #expect(abs(MonotonicClock.seconds(fromMachTicks: mach_absolute_time()) - MonotonicClock.now()) < 0.001)
    #expect(abs(MonotonicClock.seconds(fromMachTicks: mach_absolute_time()) - Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9) < 0.001)
    #expect(MonotonicClock.seconds(fromNanoseconds: 1_500_000_000) == 1.5)
}
