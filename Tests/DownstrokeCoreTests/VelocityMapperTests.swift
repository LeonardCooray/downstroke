import Testing
@testable import DownstrokeCore

@Suite struct VelocityMapperTests {
    @Test func velocityCurve() throws {
        let mapper = VelocityMapper(sensitivity: 0.5)
        #expect(mapper.velocity(forPeak: 0.004) == 0)
        #expect(mapper.velocity(forPeak: 0.005) == 0)
        #expect(mapper.velocity(forPeak: 0.06) == 1)
        #expect(abs(try #require(mapper.velocity(forPeak: 0.0173)) - 0.5) < 0.02)
        #expect(mapper.velocity(forPeak: 0.5) == nil)
    }

    @Test func bumpThresholdIsInclusiveAtPointThree() {
        let mapper = VelocityMapper(sensitivity: 0.5)
        #expect(mapper.velocity(forPeak: 0.3) == 1)
        #expect(mapper.velocity(forPeak: 0.3001) == nil)
    }

    @Test func sensitivityMovesCeiling() {
        #expect(VelocityMapper(sensitivity: 1).velocity(forPeak: 0.03) == 1)
        #expect(VelocityMapper(sensitivity: 0).velocity(forPeak: 0.12) == 1)
    }
}
