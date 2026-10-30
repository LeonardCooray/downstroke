import Foundation
import Testing
@testable import DownstrokeCore

private struct SeededRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ range: ClosedRange<Float>) -> Float {
        let unit = Float(next() >> 40) / Float(1 << 24)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private let sampleRate = 800.0
private let noiseAmplitude: Float = 0.0006
private let burstShape: [Float] = [1, 0.6, 0.3, 0.15]

/// Gravity on z, low noise, and an optional decaying burst starting at `impulseAt` seconds.
private func makeSamples(
    duration: Double, impulseAt: Double? = nil, amplitude: Float = 0, seed: UInt64 = 42
) -> [AccelSample] {
    var rng = SeededRNG(state: seed)
    let count = Int(duration * sampleRate) + 1
    let impulseStart = impulseAt.map { Int(($0 * sampleRate).rounded()) }
    return (0..<count).map { i in
        var z: Float = 1
        if let start = impulseStart, i >= start, i - start < burstShape.count {
            z += amplitude * burstShape[i - start]
        }
        return AccelSample(
            time: Double(i) / sampleRate,
            x: rng.uniform(-noiseAmplitude...noiseAmplitude),
            y: rng.uniform(-noiseAmplitude...noiseAmplitude),
            z: z + rng.uniform(-noiseAmplitude...noiseAmplitude))
    }
}

private func makeRing(_ samples: [AccelSample]) -> SampleRing {
    let ring = SampleRing()
    var filter = ImpactFilter()
    for s in samples { ring.append(time: s.time, impact: filter.process(s)) }
    return ring
}

@Suite struct SensorTests {
    @Test func filterRemovesGravity() {
        var filter = ImpactFilter()
        let outputs = (0..<800).map { i in
            filter.process(AccelSample(time: Double(i) / sampleRate, x: 0, y: 0, z: 1))
        }
        #expect(outputs.suffix(400).allSatisfy { $0 < 0.0005 })
    }

    @Test func peakFindsBottomOutInsideWindow() throws {
        let keyTime = 0.5
        let ring = makeRing(makeSamples(duration: 0.7, impulseAt: keyTime + 0.007, amplitude: 0.012))
        let peak = try #require(ImpactAnalyzer.peak(in: ring, keyTime: keyTime))
        #expect(abs(peak - 0.012) < 0.002)
    }

    @Test func peakIgnoresImpulseOutsideWindow() throws {
        let keyTime = 0.5
        let ring = makeRing(makeSamples(duration: 0.7, impulseAt: keyTime + 0.020, amplitude: 0.012))
        let peak = try #require(ImpactAnalyzer.peak(in: ring, keyTime: keyTime))
        #expect(peak < 0.002)
    }

    @Test func peakSeesImpulseInPreWindow() throws {
        let keyTime = 0.5
        let ring = makeRing(makeSamples(duration: 0.7, impulseAt: keyTime - 0.010, amplitude: 0.012))
        let peak = try #require(ImpactAnalyzer.peak(in: ring, keyTime: keyTime))
        #expect(abs(peak - 0.012) < 0.002)
    }

    @Test func peakIsNilBeforeWindowCloses() {
        let keyTime = 0.5
        let ring = makeRing(makeSamples(duration: keyTime + 0.005, impulseAt: keyTime + 0.003, amplitude: 0.012))
        #expect(ImpactAnalyzer.peak(in: ring, keyTime: keyTime) == nil)
    }

    @Test func peakIsNilForEmptyRing() {
        #expect(ImpactAnalyzer.peak(in: SampleRing(), keyTime: 1) == nil)
        #expect(SampleRing().latestTime == nil)
    }

    @Test func ringWrapsKeepingNewest() {
        let ring = SampleRing(capacity: 8)
        for i in 0..<20 { ring.append(time: Double(i), impact: Float(i) * 10) }
        #expect(ring.impacts(from: 0, to: 100) == [120, 130, 140, 150, 160, 170, 180, 190])
        #expect(ring.impacts(from: 15, to: 17) == [150, 160, 170])
        #expect(ring.latestTime == 19)
    }

    @Test func ringReadsStayConsistentUnderConcurrentAppends() async {
        let ring = SampleRing(capacity: 64)
        let total = 300_000
        let writer = Task.detached {
            for i in 0..<total { ring.append(time: Double(i), impact: Float(i)) }
        }
        var inconsistent = 0
        while ring.latestTime != Double(total - 1) {
            let values = ring.impacts(from: 0, to: Double(total))
            for pair in zip(values, values.dropFirst()) where pair.1 != pair.0 + 1 { inconsistent += 1 }
        }
        await writer.value
        #expect(inconsistent == 0)
    }
}
