import Foundation
import Synchronization

/// One accelerometer reading in g, stamped on the MonotonicClock timebase.
public struct AccelSample: Sendable {
    public var time: Double
    public var x: Float
    public var y: Float
    public var z: Float

    public init(time: Double, x: Float, y: Float, z: Float) {
        self.time = time
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Second-order Butterworth high-pass per axis; returns the filtered vector magnitude in g.
public struct ImpactFilter: Sendable {
    private struct Biquad {
        var z1 = 0.0
        var z2 = 0.0
    }

    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var x = Biquad()
    private var y = Biquad()
    private var z = Biquad()
    private var primed = false

    public init(sampleRate: Double = 800, cutoff: Double = 5) {
        let k = tan(Double.pi * cutoff / sampleRate)
        let norm = 1 / (1 + 2.0.squareRoot() * k + k * k)
        b0 = norm
        b1 = -2 * norm
        b2 = norm
        a1 = 2 * (k * k - 1) * norm
        a2 = (1 - 2.0.squareRoot() * k + k * k) * norm
    }

    public mutating func process(_ s: AccelSample) -> Float {
        if !primed {
            // Start in the steady state for the first reading so gravity doesn't ring in.
            x = steadyState(Double(s.x))
            y = steadyState(Double(s.y))
            z = steadyState(Double(s.z))
            primed = true
        }
        let fx = step(&x, Double(s.x))
        let fy = step(&y, Double(s.y))
        let fz = step(&z, Double(s.z))
        return Float((fx * fx + fy * fy + fz * fz).squareRoot())
    }

    private func steadyState(_ input: Double) -> Biquad {
        Biquad(z1: -b0 * input, z2: b2 * input)
    }

    private func step(_ q: inout Biquad, _ input: Double) -> Double {
        let out = b0 * input + q.z1
        q.z1 = b1 * input - a1 * out + q.z2
        q.z2 = b2 * input - a2 * out
        return out
    }
}

/// Filters samples into a ring; a gap or reset re-primes the filter and marks the ring unsettled.
public struct ImpactStream: Sendable {
    /// A gap longer than this between samples re-primes the filter.
    public static let restartGap = 0.1
    /// The 5 Hz filter's step response stays under 1% of a priming error from 164 ms on.
    public static let settleTime = 0.2

    private var filter = ImpactFilter()
    private var lastTime = -Double.infinity
    private var resetRequested = false

    public init() {}

    /// Re-primes on the next sample.
    public mutating func reset() { resetRequested = true }

    /// Single writer, like `SampleRing.append`.
    public mutating func append(_ s: AccelSample, to ring: SampleRing) {
        if resetRequested || s.time - lastTime > Self.restartGap {
            filter = ImpactFilter()
            resetRequested = false
            ring.markReprimed(at: s.time)
        }
        lastTime = s.time
        ring.append(time: s.time, impact: filter.process(s))
    }
}

/// Fixed-size history of filtered impacts. One writer appends; any thread may read.
public final class SampleRing: @unchecked Sendable {
    private let capacity: Int
    private let times: UnsafeMutablePointer<Atomic<UInt64>>
    private let impactBits: UnsafeMutablePointer<Atomic<UInt32>>
    private let written = Atomic<Int>(0)
    private let writing = Atomic<Int>(0)
    private let reprimeBits = Atomic<UInt64>((-Double.infinity).bitPattern)

    public init(capacity: Int = 4096) {
        precondition(capacity >= 2, "capacity must be at least 2")
        self.capacity = capacity
        times = .allocate(capacity: capacity)
        impactBits = .allocate(capacity: capacity)
        for i in 0..<capacity {
            (times + i).initialize(to: Atomic(0))
            (impactBits + i).initialize(to: Atomic(0))
        }
    }

    deinit {
        times.deinitialize(count: capacity)
        impactBits.deinitialize(count: capacity)
        times.deallocate()
        impactBits.deallocate()
    }

    /// Single writer only; wait-free and allocation-free.
    public func append(time: Double, impact: Float) {
        let n = written.load(ordering: .relaxed)
        let slot = n % capacity
        // Announce the slot reuse before touching it so readers can discard it.
        writing.store(n + 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .acquiringAndReleasing)
        times[slot].store(time.bitPattern, ordering: .relaxed)
        impactBits[slot].store(impact.bitPattern, ordering: .relaxed)
        written.store(n + 1, ordering: .releasing)
    }

    /// Single writer, before appending the sample the filter re-primed on.
    public func markReprimed(at time: Double) {
        reprimeBits.store(time.bitPattern, ordering: .releasing)
    }

    /// Time of the latest filter re-prime; impacts for `ImpactStream.settleTime` after it may carry a priming error.
    public var lastReprime: Double { Double(bitPattern: reprimeBits.load(ordering: .acquiring)) }

    /// Samples appended so far.
    public var count: Int { written.load(ordering: .relaxed) }

    public var latestTime: Double? {
        let n = written.load(ordering: .acquiring)
        guard n > 0 else { return nil }
        return Double(bitPattern: times[(n - 1) % capacity].load(ordering: .relaxed))
    }

    /// Impacts stamped within `from...to`, oldest first. May allocate; never blocks the writer.
    public func impacts(from: Double, to: Double) -> [Float] {
        let end = written.load(ordering: .acquiring)
        let start = max(0, end - capacity)
        var snapshot: [(time: Double, impact: Float)] = []
        snapshot.reserveCapacity(end - start)
        for i in start..<end {
            let slot = i % capacity
            snapshot.append((
                Double(bitPattern: times[slot].load(ordering: .relaxed)),
                Float(bitPattern: impactBits[slot].load(ordering: .relaxed))))
        }
        // Entries the writer may have reused while we copied are dropped.
        atomicMemoryFence(ordering: .acquiringAndReleasing)
        let safeStart = max(start, writing.load(ordering: .relaxed) - capacity)
        return snapshot.dropFirst(safeStart - start)
            .filter { $0.time >= from && $0.time <= to }
            .map(\.impact)
    }
}

public enum ImpactAnalyzer {
    public static let preMs = 15.0
    public static let postMs = 8.0

    /// Largest filtered impact from `preMs` before to `postMs` after the key event; nil until that window has been sampled.
    public static func peak(
        in ring: SampleRing, keyTime: Double, preMs: Double = preMs, postMs: Double = postMs
    ) -> Float? {
        let windowEnd = keyTime + postMs / 1000
        guard let latest = ring.latestTime, latest >= windowEnd else { return nil }
        return ring.impacts(from: keyTime - preMs / 1000, to: windowEnd).max()
    }

    /// False when the press window overlaps the settle time after the latest re-prime.
    public static func isSettled(in ring: SampleRing, keyTime: Double, preMs: Double = preMs, postMs: Double = postMs) -> Bool {
        let reprime = ring.lastReprime
        return keyTime + postMs / 1000 < reprime || keyTime - preMs / 1000 >= reprime + ImpactStream.settleTime
    }
}
