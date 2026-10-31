import DownstrokeCore
import Testing

@Test func latencyPercentiles() {
    var stats = LatencyStats()
    #expect(stats.p50 == nil && stats.p99 == nil && stats.count == 0)
    for ms in 1...100 { stats.add(Double(ms) / 1000) }
    #expect(stats.count == 100)
    #expect(abs((stats.p50 ?? -1) - 0.050) < 1e-9)
    #expect(abs((stats.p99 ?? -1) - 0.099) < 1e-9)
}

@Test func latencyKeepsLast512() {
    var stats = LatencyStats()
    for i in 0..<600 { stats.add(i < 88 ? 1 : 0.001) }
    #expect(stats.count == 512)
    #expect(stats.p99 == 0.001)
}
