import Darwin

/// Seconds on the mach clock, the same timebase as CGEvent and IOKit timestamps.
public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> Double {
        seconds(fromMachTicks: mach_absolute_time())
    }

    public static func seconds(fromMachTicks ticks: UInt64) -> Double {
        seconds(fromNanoseconds: ticks &* UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    public static func seconds(fromNanoseconds nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000_000
    }
}
