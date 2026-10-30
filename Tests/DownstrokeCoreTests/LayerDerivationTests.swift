import DownstrokeCore
import Foundation
import Testing

private let rate = 48000.0

/// 4 kHz Butterworth-style high-pass (RBJ), independent of the code under test.
private func highPassed(_ x: [Float]) -> [Float] {
    let w0 = 2 * Double.pi * 4000 / rate, c = cos(w0), alpha = sin(w0) / (2 * 0.7071)
    let a0 = 1 + alpha
    let b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = b0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    return x.map { sample in
        let v = Double(sample)
        let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = v; y2 = y1; y1 = y
        return Float(y)
    }
}

private func firstIndexAbove(_ x: [Float], _ threshold: Float) -> Int? { x.firstIndex { abs($0) > threshold } }

@Test func softIsDarkerAndQuieter() {
    let hard = PCMClip(left: whiteNoise(frames: 480, amplitude: 0.9))
    let layers = LayerDerivation.derive(from: hard, sampleRate: rate)
    let soft = layers[.soft]!, medium = layers[.medium]!, loud = layers[.hard]!
    #expect(rms(soft.left) < rms(medium.left))
    #expect(rms(medium.left) < rms(loud.left))
    let energy = { (c: PCMClip) in highPassed(c.left).reduce(0.0) { $0 + Double($1) * Double($1) } }
    #expect(energy(soft) < 0.2 * energy(loud))
}

@Test func slamNeverExceedsFullScale() {
    var samples = whiteNoise(frames: 480, amplitude: 0.99)
    samples[0] = 0.99
    let layers = LayerDerivation.derive(from: PCMClip(left: samples), sampleRate: rate)
    let slam = layers[.slam]!
    #expect(peak(slam.left) <= 1.0)
    #expect(rms(slam.left) > rms(samples))
}

@Test func derivationKeepsLengthAndOnset() {
    var samples = whiteNoise(frames: 960, amplitude: 0.6)
    samples[0] = 0.9
    let hard = PCMClip(left: samples, right: samples)
    let layers = LayerDerivation.derive(from: hard, sampleRate: rate)
    #expect(layers.count == Layer.allCases.count)
    let hardOnset = firstIndexAbove(hard.left, 0.01)!
    let window = Int(0.0008 * rate)
    for (layer, clip) in layers {
        #expect(clip.frameCount == hard.frameCount)
        #expect(clip.right?.count == hard.frameCount)
        let onset = firstIndexAbove(clip.left, 0.01)!
        if layer == .soft {
            #expect(onset >= hardOnset && onset <= hardOnset + window)
        } else {
            #expect(onset == hardOnset)
        }
    }
    #expect(layers[.hard]!.left == hard.left)
}

@Test func layerCentres() {
    #expect(Layer.allCases.map(\.centre) == [0.125, 0.375, 0.625, 0.875])
}

private func sine(_ hz: Double, amplitude: Double, seconds: Double = 0.1) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
}

private func gainDB(_ layer: Layer, hz: Double, amplitude: Double) -> Double {
    let input = sine(hz, amplitude: amplitude)
    let output = LayerDerivation.derive(from: PCMClip(left: input), sampleRate: rate)[layer]!.left
    let back = { (x: [Float]) in rms(Array(x[(x.count / 2)...])) }
    return 20 * log10(back(output) / back(input))
}

@Test func softAttenuatesTwelveDBAtCutoff() {
    #expect(abs(gainDB(.soft, hz: 2800, amplitude: 0.5) - -12.0) < 0.5)
}

@Test func mediumAttenuatesFivePointFiveDBAtCutoff() {
    #expect(abs(gainDB(.medium, hz: 6500, amplitude: 0.5) - -5.5) < 0.5)
}

@Test func slamBoostsLowEndBySixPointNineDB() {
    #expect(abs(gainDB(.slam, hz: 50, amplitude: 0.05) - 6.9) < 0.5)
}
