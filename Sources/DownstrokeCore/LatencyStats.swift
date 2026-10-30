/// Percentiles over the last 512 latencies, in seconds.
public struct LatencyStats: Sendable {
    public static let window = 512
    private var values: [Double] = []
    private var next = 0

    public init() {}

    public mutating func add(_ s: Double) {
        if values.count < Self.window { values.append(s) } else { values[next] = s }
        next = (next + 1) % Self.window
    }

    /// Values currently in the window.
    public var count: Int { values.count }
    public var p50: Double? { percentile(0.50) }
    public var p99: Double? { percentile(0.99) }

    // Nearest rank: the smallest value with at least p of the samples at or below it.
    private func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count) - 1e-9).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
