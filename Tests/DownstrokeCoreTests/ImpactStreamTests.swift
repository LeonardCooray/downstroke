@testable import DownstrokeCore
import Foundation
import Testing

private let rate = 800.0

private struct StreamRig {
    let queue = TriggerQueue()
    let ring = SampleRing()
    let pipeline: TypingPipeline
    var stream = ImpactStream()

    init() {
        pipeline = TypingPipeline(queue: queue, ring: ring, random: SeededRandom(state: 5))
        var settings = DownstrokeSettings()
        settings.hitStrengthEnabled = true
        pipeline.update(settings: settings, bank: sharedBank, sensorAvailable: true)
        pipeline.setContext(frontmostBundleID: nil, micInUse: false)
    }

    /// Gravity on z from `from` to `to` at 800 Hz; `firstOffset` is added to the first sample, `impulseAt` adds a one-sample bump.
    mutating func feed(from: Double, to: Double, firstOffset: Float = 0, impulseAt: Double? = nil, impulse: Float = 0) {
        let count = Int(((to - from) * rate).rounded())
        let impulseIndex = impulseAt.map { Int((($0 - from) * rate).rounded()) }
        for i in 0..<count {
            var z: Float = 1
            if i == 0 { z += firstOffset }
            if i == impulseIndex { z += impulse }
            stream.append(AccelSample(time: from + Double(i) / rate, x: 0, y: 0, z: z), to: ring)
        }
    }

    func press(at time: Double) -> [Slot] {
        pipeline.keyEvent(KeyEvent(time: time, keyCode: 0, isRelease: false, isModifier: false), now: time + 0.0085)
        return drain(queue).map { slot(of: $0, in: sharedBank) }
    }
}

private let normal: [Slot] = [.press(.medium), .press(.hard)]
private let threshold = SlamMapper(sensitivity: 0.5).threshold

@Test func misprimeAfterAGapPlaysNormal() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1)
    // The first sample after a 0.3 s gap is caught 40 mg off its baseline, mid-transient.
    rig.feed(from: 1.3, to: 2, firstOffset: 0.04)
    let peak = ImpactAnalyzer.peak(in: rig.ring, keyTime: 1.32) ?? 0
    #expect(peak > threshold, "the mis-prime alone reads as a slam (\(peak) g)")
    #expect(rig.press(at: 1.32) == normal)
    #expect(rig.pipeline.slamCount == 0)
}

@Test func misprimeRingingBackStillPlaysNormal() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1)
    // A large mis-prime: the filter's undershoot lobe is still ~15% of it 100 ms later.
    rig.feed(from: 1.3, to: 2, firstOffset: 0.15)
    let peak = ImpactAnalyzer.peak(in: rig.ring, keyTime: 1.40) ?? 0
    #expect(peak > threshold, "the undershoot reads as a slam (\(peak) g)")
    #expect(rig.press(at: 1.40) == normal)
}

@Test func slamAfterTheSettleWindowStillCounts() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1)
    let pressTime = 1.3 + ImpactStream.settleTime + 0.015 + 0.01
    rig.feed(from: 1.3, to: 2, firstOffset: 0.04, impulseAt: pressTime, impulse: 0.06)
    #expect(rig.press(at: pressTime) == [.press(.slam)])
    #expect(rig.pipeline.slamCount == 1)
}

@Test func reprimeAfterThePressWindowKeepsItsSlam() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1.01, impulseAt: 1.0, impulse: 0.06)
    // The sample after a stall re-primes before the press resolves, but the press window was clean.
    rig.feed(from: 1.15, to: 1.2)
    rig.pipeline.keyEvent(KeyEvent(time: 1.0, keyCode: 0, isRelease: false, isModifier: false), now: 1.16)
    #expect(drain(rig.queue).map { slot(of: $0, in: sharedBank) } == [.press(.slam)])
}

@Test func firstPrimeAtSensorStartAlsoSettles() {
    var rig = StreamRig()
    rig.feed(from: 1, to: 2, firstOffset: 0.04)
    #expect(rig.press(at: 1.02) == normal)
}

@Test func shortGapKeepsTheFilterAndSlams() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1)
    rig.feed(from: 1.05, to: 2, impulseAt: 1.06, impulse: 0.06)
    #expect(rig.press(at: 1.06) == [.press(.slam)])
}

@Test func resetReprimesAndSettles() {
    var rig = StreamRig()
    rig.feed(from: 0, to: 1)
    rig.stream.reset()
    rig.feed(from: 1, to: 2, firstOffset: 0.04, impulseAt: 1.02, impulse: 0.06)
    #expect(rig.press(at: 1.02) == normal)
}

@Test func settleWindowCoversThePressWindowStart() {
    let ring = SampleRing()
    ring.markReprimed(at: 1.8)
    #expect(!ImpactAnalyzer.isSettled(in: ring, keyTime: 2.0145))
    #expect(ImpactAnalyzer.isSettled(in: ring, keyTime: 2.0155))
    #expect(!ImpactAnalyzer.isSettled(in: ring, keyTime: 1.7925))
    #expect(ImpactAnalyzer.isSettled(in: ring, keyTime: 1.7915))
    #expect(ImpactAnalyzer.isSettled(in: SampleRing(), keyTime: 0))
}

@Test func settleTimeCoversTheFilterStepResponse() {
    // A primed filter fed a 1 g step must stay under 1% of it from the settle time on.
    var filter = ImpactFilter()
    _ = filter.process(AccelSample(time: 0, x: 0, y: 0, z: 1))
    var worst: Float = 0
    for i in 1..<Int(rate) {
        let t = Double(i) / rate
        let out = filter.process(AccelSample(time: t, x: 0, y: 0, z: 0))
        if t >= ImpactStream.settleTime { worst = max(worst, out) }
    }
    #expect(worst < 0.01)
}
