import Foundation

/// Normal presses play at a fixed strength; a press over the threshold ramps to the slam layer.
public struct SlamMapper: Sendable {
    public static let normalVelocity: Float = 0.5
    public static let slamVelocity: Float = 0.875
    public static let bumpThreshold: Float = 0.3
    // Below ~13 mg ordinary typing starts reading as slams, so the easy half is narrower.
    private static let hardest: Float = 0.030
    private static let middle: Float = 0.0155
    private static let easiest: Float = 0.013

    /// Filtered impact in g where a press starts counting as a slam.
    public let threshold: Float

    public init(sensitivity: Float) {
        let s = min(max(sensitivity, 0), 1)
        threshold = s <= 0.5
            ? Self.hardest * pow(Self.middle / Self.hardest, 2 * s)
            : Self.middle * pow(Self.easiest / Self.middle, 2 * s - 1)
    }

    public func velocity(forPeak g: Float) -> Float {
        guard g <= Self.bumpThreshold, g > threshold else { return Self.normalVelocity }
        let t = min((g / threshold - 1) / 0.5, 1)
        return Self.normalVelocity + (Self.slamVelocity - Self.normalVelocity) * t
    }

    /// 0...1 for the panel meter, with the threshold at 0.5.
    public func meterLevel(forPeak g: Float) -> Float {
        guard g <= Self.bumpThreshold else { return 0 }
        return min(max(g / (2 * threshold), 0), 1)
    }
}
