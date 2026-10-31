import Foundation

/// Turns a key event and a velocity into the triggers to start, with the per-press variation applied.
public struct TriggerPlanner {
    public var random: any RandomNumberGenerator

    // Last recording index per group, so a group never repeats a recording back to back.
    private var lastPress = [Int](repeating: -1, count: KeyGroup.allCases.count)
    // Per-list last index, for blends whose layers hold different numbers of clips.
    private var lastLayerPress = [Int](repeating: -1, count: KeyGroup.allCases.count * Layer.allCases.count)
    private var lastRelease = [Int](repeating: -1, count: KeyGroup.allCases.count)

    public init(random: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.random = random
    }

    /// Allocates; call from producer threads only.
    public mutating func plan(_ e: KeyEvent, velocity: Float, bank: SampleBank, settings: DownstrokeSettings) -> [Trigger] {
        let group = KeyClassifier.group(for: e.keyCode)
        let groupIndex = KeyGroup.allCases.firstIndex(of: group)!
        let pan = (KeyLayout.position(for: e.keyCode) - 0.5) * 2 * settings.stereoWidth
        let rate = uniform(0.97...1.03)

        if e.isRelease {
            guard settings.keyUpSounds else { return [] }
            let clips = bank.releases(group)
            guard let index = pick(from: clips.count, last: lastRelease[groupIndex]) else { return [] }
            lastRelease[groupIndex] = index
            let gain = 0.6 * uniform(0.9...1.1)
            return [Trigger(clip: clips[index], gain: gain, pan: pan, rate: rate, eventTime: e.time, bankTag: bank.tag)]
        }

        let v = min(max(velocity, 0), 1)
        let base = (0.55 + 0.45 * v) * uniform(0.9...1.1)
        let layers = Self.layers(for: v)
        let lists = layers.map { bank.presses(group, $0.0) }
        // Derived layers line up by index, so one recording index serves every layer of the blend.
        var shared: Int?
        if lists.allSatisfy({ $0.count == lists[0].count }) {
            guard let index = pick(from: lists[0].count, last: lastPress[groupIndex]) else { return [] }
            lastPress[groupIndex] = index
            shared = index
        }
        var out: [Trigger] = []
        for ((layer, weight), clips) in zip(layers, lists) {
            let slot = groupIndex * Layer.allCases.count + layer.rawValue
            guard let index = shared ?? pick(from: clips.count, last: lastLayerPress[slot]) else { continue }
            lastLayerPress[slot] = index
            out.append(Trigger(
                clip: clips[index], gain: base * weight, pan: pan, rate: rate, eventTime: e.time, bankTag: bank.tag,
                recordsLatency: out.isEmpty))
        }
        return out
    }

    /// The nearest layer, or the two nearest with linear weights between their centres.
    static func layers(for v: Float) -> [(Layer, Float)] {
        let position = v * Float(Layer.allCases.count) - 0.5
        guard position > 0 else { return [(.soft, 1)] }
        guard position < Float(Layer.allCases.count - 1) else { return [(.slam, 1)] }
        let lower = Int(position)
        let t = position - Float(lower)
        let a = Layer(rawValue: lower)!, b = Layer(rawValue: lower + 1)!
        if t == 0 { return [(a, 1)] }
        return [(a, 1 - t), (b, t)]
    }

    private struct Erased: RandomNumberGenerator {
        var base: any RandomNumberGenerator
        mutating func next() -> UInt64 { base.next() }
    }

    private mutating func uniform(_ range: ClosedRange<Float>) -> Float {
        var g = Erased(base: random)
        defer { random = g.base }
        return Float.random(in: range, using: &g)
    }

    private mutating func uniformIndex(_ count: Int) -> Int {
        var g = Erased(base: random)
        defer { random = g.base }
        return Int.random(in: 0..<count, using: &g)
    }

    // Random index in 0..<count, never `last` unless it is the only one.
    private mutating func pick(from count: Int, last: Int) -> Int? {
        guard count > 0 else { return nil }
        var index = uniformIndex(count)
        if count > 1, index == last { index = (index + (1 + uniformIndex(count - 1))) % count }
        return index
    }
}
