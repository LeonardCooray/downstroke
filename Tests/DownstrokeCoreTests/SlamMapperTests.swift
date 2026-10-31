@testable import DownstrokeCore
import Testing

@Suite struct SlamMapperTests {
    @Test func thresholdFollowsSensitivityOnALogScale() {
        #expect(abs(SlamMapper(sensitivity: 0).threshold - 0.030) < 1e-6)
        #expect(abs(SlamMapper(sensitivity: 1).threshold - 0.008) < 1e-6)
        #expect(abs(SlamMapper(sensitivity: 0.5).threshold - 0.01549) < 1e-4)
        #expect(SlamMapper(sensitivity: -1).threshold == SlamMapper(sensitivity: 0).threshold)
        #expect(SlamMapper(sensitivity: 2).threshold == SlamMapper(sensitivity: 1).threshold)
    }

    @Test func belowThresholdIsExactlyNormal() {
        let m = SlamMapper(sensitivity: 0.5)
        #expect(m.velocity(forPeak: 0) == 0.5)
        #expect(m.velocity(forPeak: m.threshold * 0.5) == 0.5)
        #expect(m.velocity(forPeak: m.threshold * 0.99) == 0.5)
        #expect(m.velocity(forPeak: m.threshold) == 0.5)
    }

    @Test func rampsToSlamAtOneAndAHalfTimesThreshold() {
        let m = SlamMapper(sensitivity: 0.5)
        #expect(abs(m.velocity(forPeak: m.threshold * 1.25) - 0.6875) < 1e-4)
        #expect(m.velocity(forPeak: m.threshold * 1.5) == 0.875)
        #expect(m.velocity(forPeak: m.threshold * 3) == 0.875)
    }

    @Test func bumpsPlayNormalAndShowNothing() {
        let m = SlamMapper(sensitivity: 0.5)
        #expect(m.velocity(forPeak: 0.31) == 0.5)
        #expect(m.meterLevel(forPeak: 0.31) == 0)
        #expect(m.velocity(forPeak: 0.3) == 0.875)
    }

    @Test func meterPutsThresholdAtTheMiddle() {
        let m = SlamMapper(sensitivity: 0.5)
        #expect(abs(m.meterLevel(forPeak: m.threshold) - 0.5) < 1e-6)
        #expect(m.meterLevel(forPeak: m.threshold * 4) == 1)
        #expect(m.meterLevel(forPeak: 0) == 0)
    }
}
