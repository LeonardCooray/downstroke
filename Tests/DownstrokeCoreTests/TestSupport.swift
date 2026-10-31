import DownstrokeCore
import Foundation
import Testing

func repoRoot(file: String = #filePath) -> URL {
    var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
        dir.deleteLastPathComponent()
    }
    return dir
}

func vendoredBoard(_ id: String) throws -> Board {
    let boards = try PackLibrary.load(from: repoRoot().appendingPathComponent("Resources/SoundPacks"))
    return try #require(boards.first { $0.id == id })
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("downstroke-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a 16-bit PCM WAV, mono for one channel and stereo for two.
func writeWAV(_ channels: [[Float]], rate: Int = 44100, to url: URL) throws {
    let frames = channels[0].count, count = channels.count
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + frames * count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(count))
    put(UInt32(rate)); put(UInt32(rate * count * 2)); put(UInt16(count * 2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); put(UInt32(frames * count * 2))
    for i in 0..<frames {
        for c in 0..<count { put(Int16((max(-1, min(1, channels[c][i])) * 32767).rounded())) }
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func whiteNoise(frames: Int, amplitude: Float, seed: UInt64 = 1) -> [Float] {
    var rng = SeededRandom(state: seed)
    return (0..<frames).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
}

func rms(_ x: [Float]) -> Double {
    (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
}

func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

/// One real bank shared by the trigger tests, so each test doesn't decode a board again.
let sharedBank: SampleBank = {
    do { return try SampleBank(board: vendoredBoard("holy-panda"), sampleRate: 48000) } catch { fatalError("\(error)") }
}()

func drain(_ queue: TriggerQueue) -> [Trigger] {
    var out: [Trigger] = []
    while let t = queue.pop() { out.append(t) }
    return out
}

enum Slot: Equatable { case press(Layer), release, unknown }

/// Which clip list of `bank` a trigger's clip came from, for the given key group.
func slot(of trigger: Trigger, in bank: SampleBank, group: KeyGroup = .alpha) -> Slot {
    for layer in Layer.allCases where bank.presses(group, layer).contains(where: { $0.left == trigger.clip.left }) {
        return .press(layer)
    }
    return bank.releases(group).contains { $0.left == trigger.clip.left } ? .release : .unknown
}
