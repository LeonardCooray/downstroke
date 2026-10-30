import Foundation

/// Velocity layers, centred on 0.125, 0.375, 0.625 and 0.875 of the 0...1 hit strength.
public enum Layer: Int, CaseIterable, Sendable {
    case soft, medium, hard, slam

    public var centre: Double { (Double(rawValue) + 0.5) / 4 }
}

/// RBJ Audio EQ Cookbook biquad, direct form I.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    static func lowPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW = cos(w0), alpha = sin(w0) / (2 * q)
        return Biquad((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2, 1 + alpha, -2 * cosW, 1 - alpha)
    }

    /// Low shelf with shelf slope S = 1.
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / 2 * (2.0).squareRoot()
        let beta = 2 * a.squareRoot() * alpha
        return Biquad(
            a * ((a + 1) - (a - 1) * cosW + beta),
            2 * a * ((a - 1) - (a + 1) * cosW),
            a * ((a + 1) - (a - 1) * cosW - beta),
            (a + 1) + (a - 1) * cosW + beta,
            -2 * ((a - 1) + (a + 1) * cosW),
            (a + 1) + (a - 1) * cosW - beta
        )
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

public enum LayerDerivation {
    /// Builds soft, medium and slam from a recorded hard hit; hard comes back unchanged.
    public static func derive(from hard: PCMClip, sampleRate: Double) -> [Layer: PCMClip] {
        [
            .soft: soft(hard, sampleRate),
            .medium: medium(hard, sampleRate),
            .hard: hard,
            .slam: slam(hard, sampleRate),
        ]
    }

    static func db(_ value: Double) -> Double { pow(10, value / 20) }

    private static func mapChannels(_ clip: PCMClip, _ transform: ([Float]) -> [Float]) -> PCMClip {
        PCMClip(left: transform(clip.left), right: clip.right.map(transform))
    }

    private static func soft(_ clip: PCMClip, _ sampleRate: Double) -> PCMClip {
        let gain = db(-6)
        let ramp = max(1, Int((0.0008 * sampleRate).rounded()))
        return mapChannels(clip) { samples in
            var first = Biquad.lowPass(frequency: 2800, sampleRate: sampleRate)
            var second = first
            return samples.enumerated().map { index, sample in
                var y = second.process(first.process(Double(sample))) * gain
                if index < ramp { y *= 0.5 * (1 - cos(Double.pi * Double(index) / Double(ramp))) }
                return Float(y)
            }
        }
    }

    private static func medium(_ clip: PCMClip, _ sampleRate: Double) -> PCMClip {
        let gain = db(-2.5)
        return mapChannels(clip) { samples in
            var filter = Biquad.lowPass(frequency: 6500, sampleRate: sampleRate)
            return samples.map { Float(filter.process(Double($0)) * gain) }
        }
    }

    private static func slam(_ clip: PCMClip, _ sampleRate: Double) -> PCMClip {
        let drive = db(2)
        let saturated = mapChannels(clip) { samples in
            var shelf = Biquad.lowShelf(frequency: 180, gainDB: 5, sampleRate: sampleRate)
            return samples.map { Float(tanh(shelf.process(Double($0)) * drive)) }
        }
        let peak = max(saturated.left.reduce(0) { max($0, abs($1)) }, saturated.right?.reduce(0) { max($0, abs($1)) } ?? 0)
        guard peak > 1 else { return saturated }
        let scale = 1 / peak
        return mapChannels(saturated) { $0.map { $0 * scale } }
    }
}
