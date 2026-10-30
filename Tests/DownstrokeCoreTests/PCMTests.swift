import DownstrokeCore
import Foundation
import Testing

@Test func decodesAndResamples() throws {
    let url = try vendoredBoard("holy-panda").folder.appendingPathComponent("sounds/alpha/hard/1.wav")
    let at48 = try AudioDecoder.decode(url, sampleRate: 48000)
    let at44 = try AudioDecoder.decode(url, sampleRate: 44100)
    let ratio = Double(at48.frameCount) / Double(at44.frameCount)
    #expect(abs(ratio / (48000.0 / 44100.0) - 1) < 0.01)
    for clip in [at48, at44] {
        let p = peak(clip.left)
        #expect((0.05...1.0).contains(p))
    }
}

@Test func decodeKeepsStereo() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("s.wav")
    try writeWAV([whiteNoise(frames: 4410, amplitude: 0.5, seed: 1), whiteNoise(frames: 4410, amplitude: 0.25, seed: 2)], to: url)
    let clip = try AudioDecoder.decode(url, sampleRate: 44100)
    #expect(clip.frameCount == 4410)
    let right = try #require(clip.right)
    #expect(peak(right) < peak(clip.left))
}
