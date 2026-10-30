import Foundation

/// Maps a peak impact in g to a 0...1 velocity on a log curve; nil means a bump, not a keystroke.
public struct VelocityMapper: Sendable {
    private static let floor: Float = 0.005
    private static let bumpThreshold: Float = 0.3

    private let ceiling: Float

    public init(sensitivity: Float) {
        let s = min(max(sensitivity, 0), 1)
        ceiling = 0.06 * Float(pow(4.0, Double(0.5 - s)))
    }

    public func velocity(forPeak g: Float) -> Float? {
        guard g <= Self.bumpThreshold else { return nil }
        guard g > Self.floor else { return 0 }
        let v = log(g / Self.floor) / log(ceiling / Self.floor)
        return min(max(v, 0), 1)
    }
}
