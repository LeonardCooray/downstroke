@testable import DownstrokeCore
import Foundation
import Testing

private let capturePath = ProcessInfo.processInfo.environment["DOWNSTROKE_CAPTURE"]

// Replays a `--capture` recording through the app's filter and slam mapping.
@Test(.enabled(if: capturePath != nil)) func captureReplaySeparatesSlams() throws {
    let text = try String(contentsOfFile: capturePath!, encoding: .utf8)
    let ring = SampleRing(capacity: 1 << 18)
    var filter = ImpactFilter()
    var presses: [(time: Double, block: Int)] = []
    var labels: [String] = []
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 3, let time = Double(f[1]) else { continue }
        switch f[0] {
        case "s":
            let s = AccelSample(time: time, x: Float(f[2])!, y: Float(f[3])!, z: Float(f[4])!)
            ring.append(time: time, impact: filter.process(s))
        case "p": labels.append(String(f[2]))
        case "d": presses.append((time, labels.count - 1))
        default: break
        }
    }
    let mapper = SlamMapper(sensitivity: 0.5)
    var slams: [Int: (slam: Int, total: Int)] = [:]
    for p in presses {
        guard let peak = ImpactAnalyzer.peak(in: ring, keyTime: p.time) else { continue }
        let slam = mapper.velocity(forPeak: peak) > SlamMapper.normalVelocity
        slams[p.block, default: (0, 0)].total += 1
        if slam { slams[p.block, default: (0, 0)].slam += 1 }
    }
    let lastHard = try #require(labels.lastIndex(of: "hard"))
    var others = (slam: 0, total: 0)
    for (block, c) in slams.sorted(by: { $0.key < $1.key }) {
        print("replay block \(block) \(labels[block]): \(c.slam)/\(c.total) slams")
        if block != lastHard && labels[block] != "palm" { others.slam += c.slam; others.total += c.total }
    }
    let hard = try #require(slams[lastHard])
    #expect(Double(hard.slam) / Double(hard.total) >= 0.6)
    #expect(Double(others.slam) / Double(others.total) <= 0.1)
}
