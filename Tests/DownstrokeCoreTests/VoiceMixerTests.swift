@testable import DownstrokeCore
import Darwin
import Foundation
import Testing

private let blockFrames = 128

/// A clip over freshly allocated buffers; release it with `freeClip`.
func makeClip(_ left: [Float], right: [Float]? = nil) -> ClipRef {
    let l = UnsafeMutablePointer<Float>.allocate(capacity: left.count)
    l.initialize(from: left, count: left.count)
    var r: UnsafeMutablePointer<Float>?
    if let right {
        r = UnsafeMutablePointer<Float>.allocate(capacity: right.count)
        r!.initialize(from: right, count: right.count)
    }
    return ClipRef(left: UnsafePointer(l), right: r.map { UnsafePointer($0) }, frames: left.count)
}

func freeClip(_ clip: ClipRef) {
    UnsafeMutablePointer(mutating: clip.left).deallocate()
    clip.right.map { UnsafeMutablePointer(mutating: $0).deallocate() }
}

private final class Output {
    let left = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
    init() {
        left.initialize(repeating: 7, count: blockFrames)
        right.initialize(repeating: 7, count: blockFrames)
    }
    deinit { left.deallocate(); right.deallocate() }
    var l: [Float] { Array(UnsafeBufferPointer(start: left, count: blockFrames)) }
    var r: [Float] { Array(UnsafeBufferPointer(start: right, count: blockFrames)) }
}

private func render(_ mixer: VoiceMixer, _ out: Output, at hostTime: Double = 0) {
    mixer.render(frames: blockFrames, hostTime: hostTime, left: out.left, right: out.right)
}

private func trigger(_ clip: ClipRef, gain: Float = 1, pan: Float = 0, rate: Float = 1, time: Double = 0, tag: Int = 1) -> Trigger {
    Trigger(clip: clip, gain: gain, pan: pan, rate: rate, eventTime: time, bankTag: tag)
}

@Test func rendersClipWithPanAndGain() {
    let clip = makeClip([Float](repeating: 0.5, count: 64))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    #expect(queue.push(trigger(clip, pan: -1)))
    render(mixer, out)
    #expect(abs(out.l.reduce(0, +) - 32) < 1e-4)
    #expect(abs(out.r.reduce(0, +)) < 1e-6)
    #expect(mixer.activeVoices == 0)
}

@Test func rateResamplesLinearly() {
    let clip = makeClip((0..<100).map(Float.init))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    #expect(queue.push(trigger(clip, pan: -1, rate: 0.5)))
    render(mixer, out)
    #expect(abs(out.l[0]) < 1e-6)
    #expect(abs(out.l[1] - 0.5) < 1e-5)
}

@Test func stereoClipKeepsChannelsApart() {
    let clip = makeClip([Float](repeating: 0.25, count: 64), right: [Float](repeating: -0.5, count: 64))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    #expect(queue.push(trigger(clip, gain: 2)))
    render(mixer, out)
    let g = Float(2).squareRoot() / 2
    #expect(abs(out.l[10] - 0.5 * g) < 1e-5)
    #expect(abs(out.r[10] + 1.0 * g) < 1e-5)
}

@Test func stealsOldestVoiceWhenFull() {
    let clip = makeClip([Float](repeating: 0.01, count: 48000))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    #expect(queue.push(trigger(clip, pan: -1, tag: 1)))
    render(mixer, out)
    #expect(out.l[0] > 0.009)
    for _ in 0..<48 { #expect(queue.push(trigger(clip, pan: 1, tag: 2))) }
    render(mixer, out)
    #expect(mixer.activeVoices == 48)
    #expect(peak(out.l) < 1e-6)
    #expect(out.r[0] > 0.4)
}

@Test func limiterNeverExceedsFullScale() {
    let clip = makeClip([Float](repeating: 0.9, count: 4800))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    for i in 0..<48 { #expect(queue.push(trigger(clip, pan: Float(i % 3) - 1))) }
    var loudest: Float = 0
    for _ in 0..<40 {
        render(mixer, out)
        loudest = max(loudest, peak(out.l), peak(out.r))
    }
    #expect(loudest <= 1.0)
    #expect(loudest > 0.9)
}

@Test func masterGainIsSmoothedOver10ms() {
    let clip = makeClip([Float](repeating: 0.5, count: 48000))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    mixer.setSampleRate(48000)
    #expect(queue.push(trigger(clip, pan: -1)))
    render(mixer, out)
    #expect(abs(out.l[127] - 0.5) < 1e-6)
    mixer.setMasterGain(0)
    render(mixer, out)
    #expect(out.l[0] > 0.49 && out.l[127] < 0.5 && out.l[127] > 0.3)
    for _ in 0..<3 { render(mixer, out) }
    #expect(abs(out.l[127]) < 1e-6)
}

@Test func recordsLatencyAtVoiceStart() {
    let clip = makeClip([Float](repeating: 0.1, count: 64))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    #expect(queue.push(trigger(clip, time: 10.000)))
    render(mixer, out, at: 10.004)
    var latencies: [Double] = []
    mixer.drainLatencies(into: &latencies)
    #expect(latencies.count == 1)
    #expect(abs((latencies.first ?? 0) - 0.004) < 1e-9)
    mixer.drainLatencies(into: &latencies)
    #expect(latencies.count == 1)
}

private func makeBank() throws -> (SampleBank, URL) {
    let dir = try makeTempDirectory()
    let pack = dir.appendingPathComponent("r.switchcraft")
    try writeWAV([[Float](repeating: 0.5, count: 4410)], to: pack.appendingPathComponent("h.wav"))
    let manifest = #"{"formatVersion":1,"id":"r","name":"r","samples":{"alpha":{"hard":["h.wav"]}}}"#
    try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    let board = try #require(try PackLibrary.load(from: dir).first { $0.id == "r" })
    return (try SampleBank(board: board, sampleRate: 44100), dir)
}

@Test func retiredBankOutlivesVoices() throws {
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    weak var weakBank: SampleBank?
    let t0 = MonotonicClock.now()
    var dir: URL?
    do {
        let (bank, folder) = try makeBank()
        dir = folder
        weakBank = bank
        let clip = try #require(bank.presses(.alpha, .hard).first)
        #expect(queue.push(trigger(clip, tag: bank.tag)))
        render(mixer, out)
        mixer.retire(bank, after: 0.05)
    }
    defer { if let dir { try? FileManager.default.removeItem(at: dir) } }
    #expect(weakBank != nil)
    #expect(mixer.activeVoices == 1)
    // Past the deadline but the voice still plays.
    mixer.collectRetired(now: t0 + 10)
    #expect(weakBank != nil)
    var blocks = 0
    while mixer.activeVoices > 0, blocks < 1000 {
        render(mixer, out)
        blocks += 1
    }
    #expect(mixer.activeVoices == 0)
    // Voice gone but the deadline hasn't passed.
    mixer.collectRetired(now: t0)
    #expect(weakBank != nil)
    mixer.collectRetired(now: t0 + 10)
    #expect(weakBank == nil)
}

@Test func retiredBankWaitsForQueuedTriggers() throws {
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    weak var weakBank: SampleBank?
    var dir: URL?
    do {
        let (bank, folder) = try makeBank()
        dir = folder
        weakBank = bank
        let clip = try #require(bank.presses(.alpha, .hard).first)
        #expect(queue.push(trigger(clip, tag: bank.tag)))
        mixer.retire(bank, after: 0)
    }
    defer { if let dir { try? FileManager.default.removeItem(at: dir) } }
    // No render has drained the queue yet.
    mixer.collectRetired(now: MonotonicClock.now() + 10)
    #expect(weakBank != nil)
    render(mixer, out)
    mixer.collectRetired(now: MonotonicClock.now() + 10)
    #expect(weakBank != nil)
    while mixer.activeVoices > 0 { render(mixer, out) }
    render(mixer, out)
    mixer.collectRetired(now: MonotonicClock.now() + 10)
    #expect(weakBank == nil)
}

@Test func renderDoesNotAllocate() {
    let clip = makeClip([Float](repeating: 0.01, count: 1_300_000))
    defer { freeClip(clip) }
    let queue = TriggerQueue(), mixer = VoiceMixer(queue: queue), out = Output()
    let left = out.left, right = out.right
    // Other suites allocate in parallel; one quiet attempt is enough, a real leak shows every time.
    var deltas: [(blocks: Int, bytes: Int)] = []
    deltas.reserveCapacity(5)
    for _ in 0..<5 {
        for i in 0..<48 { _ = queue.push(trigger(clip, pan: Float(i % 3) - 1, time: Double(i))) }
        mixer.render(frames: blockFrames, hostTime: 1, left: left, right: right)
        var before = malloc_statistics_t(), after = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        for cycle in 0..<10_000 {
            mixer.render(frames: blockFrames, hostTime: Double(cycle), left: left, right: right)
        }
        malloc_zone_statistics(nil, &after)
        deltas.append((Int(after.blocks_in_use) - Int(before.blocks_in_use), Int(after.size_in_use) - Int(before.size_in_use)))
        #expect(mixer.activeVoices == 48)
        if deltas.last! == (0, 0) { break }
    }
    #expect(deltas.contains { $0 == (0, 0) }, "malloc deltas per attempt: \(deltas)")
}
