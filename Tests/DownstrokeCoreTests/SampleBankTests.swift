import DownstrokeCore
import Foundation
import Testing

private func writePack(_ id: String, samples: String, gain: Double = 1, derive: Bool = false, in root: URL) throws -> Board {
    let manifest = """
    {"formatVersion":1,"id":"\(id)","name":"\(id)","gain":\(gain),"deriveVelocityLayers":\(derive),"samples":\(samples)}
    """
    let pack = root.appendingPathComponent("\(id).switchcraft")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try #require(try PackLibrary.load(from: root).first { $0.id == id })
}

private let burst = whiteNoise(frames: 2205, amplitude: 0.8)

@Test func bankFallsBack() throws {
    let bank = try SampleBank(board: vendoredBoard("holy-panda"), sampleRate: 48000)
    #expect(!bank.presses(.function, .soft).isEmpty)
    #expect(!bank.releases(.space).isEmpty)
    #expect(bank.presses(.function, .slam).count == bank.presses(.alpha, .slam).count)
}

@Test func bankFitsBudget() throws {
    let boards = try PackLibrary.load(from: repoRoot().appendingPathComponent("Resources/SoundPacks"))
    var total = 0
    for board in boards {
        let bank = try SampleBank(board: board, sampleRate: 48000)
        total += bank.byteCount
    }
    print("all \(boards.count) banks at 48 kHz: \(total) bytes")
    #expect(boards.count == 20)
    #expect(total < 80_000_000)
}

@Test func banksHaveDistinctTags() throws {
    let board = try vendoredBoard("holy-panda")
    let a = try SampleBank(board: board, sampleRate: 48000)
    let b = try SampleBank(board: board, sampleRate: 48000)
    #expect(a.tag != b.tag)
}

@Test func bankDerivesLayersFromHard() throws {
    let bank = try SampleBank(board: vendoredBoard("holy-panda"), sampleRate: 48000)
    let soft = try #require(bank.presses(.alpha, .soft).first)
    let hard = try #require(bank.presses(.alpha, .hard).first)
    let slam = try #require(bank.presses(.alpha, .slam).first)
    #expect(soft.frames == hard.frames && slam.frames == hard.frames)
    #expect(soft.left != hard.left)
    #expect(bank.presses(.alpha, .hard).count == 5)
    #expect(bank.boardID == "holy-panda")
}

@Test func missingLayerUsesNearestAndTieGoesLouder() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pack = dir.appendingPathComponent("p.switchcraft")
    try writeWAV([burst.map { $0 * 0.2 }], to: pack.appendingPathComponent("s.wav"))
    try writeWAV([burst], to: pack.appendingPathComponent("h.wav"))
    let board = try writePack("p", samples: #"{"alpha":{"soft":["s.wav"],"hard":["h.wav"]}}"#, in: dir)
    let bank = try SampleBank(board: board, sampleRate: 44100)
    let peakOf = { (c: ClipRef) in UnsafeBufferPointer(start: c.left, count: c.frames).reduce(Float(0)) { max($0, abs($1)) } }
    let soft = try #require(bank.presses(.alpha, .soft).first)
    let medium = try #require(bank.presses(.alpha, .medium).first)
    let slam = try #require(bank.presses(.alpha, .slam).first)
    #expect(peakOf(soft) < 0.25)
    #expect(peakOf(medium) > 0.7)
    #expect(peakOf(slam) > 0.7)
    #expect(bank.releases(.alpha).isEmpty)
}

@Test func manifestGainScalesEverySample() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pack = dir.appendingPathComponent("g.switchcraft")
    try writeWAV([burst], to: pack.appendingPathComponent("h.wav"))
    try writeWAV([burst], to: pack.appendingPathComponent("r.wav"))
    let samples = #"{"alpha":{"hard":["h.wav"],"release":["r.wav"]}}"#
    let full = try SampleBank(board: writePack("g", samples: samples, in: dir), sampleRate: 44100)
    let half = try SampleBank(board: writePack("g", samples: samples, gain: 0.5, in: dir), sampleRate: 44100)
    for (a, b) in [(full.presses(.alpha, .hard)[0], half.presses(.alpha, .hard)[0]), (full.releases(.alpha)[0], half.releases(.alpha)[0])] {
        let x = UnsafeBufferPointer(start: a.left, count: a.frames), y = UnsafeBufferPointer(start: b.left, count: b.frames)
        #expect(zip(x, y).allSatisfy { abs($0 * 0.5 - $1) < 1e-6 })
    }
}

@Test func pathsOutsideThePackAreRefused() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeWAV([burst], to: dir.appendingPathComponent("escape.wav"))
    let pack = dir.appendingPathComponent("e.switchcraft")
    try writeWAV([burst], to: pack.appendingPathComponent("ok.wav"))
    let board = try writePack("e", samples: #"{"alpha":{"hard":["../escape.wav","ok.wav"]},"space":{"hard":["../escape.wav"]}}"#, in: dir)
    let bank = try SampleBank(board: board, sampleRate: 44100)
    #expect(bank.presses(.alpha, .hard).count == 1)
    // space has nothing usable left, so it falls back to alpha.
    #expect(bank.presses(.space, .hard).count == 1)
}

@Test func symlinkOutOfThePackIsRefused() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeWAV([burst], to: dir.appendingPathComponent("outside/escape.wav"))
    let pack = dir.appendingPathComponent("l.switchcraft")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("link.wav"), withDestinationURL: dir.appendingPathComponent("outside/escape.wav"))
    let board = try writePack("l", samples: #"{"alpha":{"hard":["link.wav"]}}"#, in: dir)
    #expect(throws: (any Error).self) { try SampleBank(board: board, sampleRate: 44100) }
}

@Test func bankWithOnlyEscapingPathsThrows() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeWAV([burst], to: dir.appendingPathComponent("escape.wav"))
    let board = try writePack("x", samples: #"{"alpha":{"hard":["../escape.wav"]}}"#, in: dir)
    #expect(throws: (any Error).self) { try SampleBank(board: board, sampleRate: 44100) }
}
