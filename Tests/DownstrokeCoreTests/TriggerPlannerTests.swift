@testable import DownstrokeCore
import Foundation
import Testing

private func press(_ code: UInt16 = 0, at time: Double = 1) -> KeyEvent {
    KeyEvent(time: time, keyCode: code, isRelease: false, isModifier: false)
}

private func release(_ code: UInt16 = 0, at time: Double = 1) -> KeyEvent {
    KeyEvent(time: time, keyCode: code, isRelease: true, isModifier: false)
}

private func planner(_ seed: UInt64 = 7) -> TriggerPlanner { TriggerPlanner(random: SeededRandom(state: seed)) }

@Test func planCrossfadesNearestLayers() {
    var p = planner()
    let settings = DownstrokeSettings()
    let mid = p.plan(press(), velocity: 0.5, bank: sharedBank, settings: settings)
    #expect(mid.count == 2)
    #expect(mid.map { slot(of: $0, in: sharedBank) } == [.press(.medium), .press(.hard)])
    #expect(abs(mid[0].gain / mid[1].gain - 1) < 1e-5)
    #expect(mid[0].rate == mid[1].rate)
    #expect(mid.allSatisfy { $0.bankTag == sharedBank.tag && $0.eventTime == 1 })

    let skewed = p.plan(press(), velocity: 0.3, bank: sharedBank, settings: settings)
    #expect(skewed.map { slot(of: $0, in: sharedBank) } == [.press(.soft), .press(.medium)])
    #expect(abs(skewed[1].gain / skewed[0].gain - 0.7 / 0.3) < 1e-4)

    let loud = p.plan(press(), velocity: 0.9, bank: sharedBank, settings: settings)
    #expect(loud.map { slot(of: $0, in: sharedBank) } == [.press(.slam)])
    let quiet = p.plan(press(), velocity: 0, bank: sharedBank, settings: settings)
    #expect(quiet.map { slot(of: $0, in: sharedBank) } == [.press(.soft)])
    let onCentre = p.plan(press(), velocity: 0.375, bank: sharedBank, settings: settings)
    #expect(onCentre.map { slot(of: $0, in: sharedBank) } == [.press(.medium)])
}

@Test func planPansByKeyPosition() throws {
    var p = planner()
    var settings = DownstrokeSettings()
    settings.stereoWidth = 1
    let left = try #require(p.plan(press(50), velocity: 0.9, bank: sharedBank, settings: settings).first)
    #expect(left.pan < -0.8)
    let right = try #require(p.plan(press(124), velocity: 0.9, bank: sharedBank, settings: settings).first)
    #expect(right.pan > 0.8)
    settings.stereoWidth = 0
    let centred = try #require(p.plan(press(50), velocity: 0.9, bank: sharedBank, settings: settings).first)
    #expect(centred.pan == 0)
}

@Test func planVariationInRange() {
    var p = planner(99)
    let settings = DownstrokeSettings()
    var gainFactors: [Float] = [], rates: [Float] = []
    for _ in 0..<1000 {
        let t = p.plan(press(), velocity: 0.9, bank: sharedBank, settings: settings)
        gainFactors.append(t[0].gain / (0.55 + 0.45 * 0.9))
        rates.append(t[0].rate)
    }
    #expect(gainFactors.allSatisfy { (0.9 - 1e-5...1.1 + 1e-5).contains($0) })
    #expect(rates.allSatisfy { (0.97...1.03).contains($0) })
    #expect(gainFactors.min()! < 0.92 && gainFactors.max()! > 1.08)
    #expect(rates.min()! < 0.98 && rates.max()! > 1.02)
}

@Test func planGainRisesWithVelocity() {
    var p = planner()
    var settings = DownstrokeSettings()
    settings.keyUpSounds = false
    let soft = p.plan(press(), velocity: 0, bank: sharedBank, settings: settings)[0].gain
    #expect(soft >= 0.55 * 0.9 - 1e-5 && soft <= 0.55 * 1.1 + 1e-5)
}

@Test func releasePlaysAtFixedGainWhenEnabled() throws {
    var p = planner()
    let settings = DownstrokeSettings()
    for _ in 0..<200 {
        let out = p.plan(release(36, at: 2), velocity: 0.5, bank: sharedBank, settings: settings)
        let t = try #require(out.first)
        #expect(out.count == 1)
        #expect(slot(of: t, in: sharedBank, group: .enter) == .release)
        #expect(t.gain >= 0.6 * 0.9 - 1e-5 && t.gain <= 0.6 * 1.1 + 1e-5)
        #expect((0.97...1.03).contains(t.rate))
        #expect(t.eventTime == 2 && t.bankTag == sharedBank.tag)
    }
}

@Test func noKeyUpWhenDisabled() {
    var p = planner()
    var settings = DownstrokeSettings()
    settings.keyUpSounds = false
    #expect(p.plan(release(), velocity: 0.5, bank: sharedBank, settings: settings).isEmpty)
}

@Test func neverSameClipTwiceInARow() throws {
    var p = planner(3)
    let settings = DownstrokeSettings()
    #expect(sharedBank.presses(.alpha, .slam).count > 1)
    var last: UnsafePointer<Float>?
    for _ in 0..<300 {
        let t = p.plan(press(), velocity: 0.9, bank: sharedBank, settings: settings)[0]
        #expect(t.clip.left != last)
        last = t.clip.left
    }
    // holy-panda has a single release clip, so use a board with many.
    let many = try SampleBank(board: vendoredBoard("cherry-mx-blue-pbt"), sampleRate: 48000)
    #expect(many.releases(.alpha).count > 1)
    var lastRelease: UnsafePointer<Float>?
    for _ in 0..<300 {
        let t = p.plan(release(), velocity: 0.5, bank: many, settings: settings)[0]
        #expect(t.clip.left != lastRelease)
        lastRelease = t.clip.left
    }
}

@Test func muteRules() {
    func play(
        enabled: Bool = true, front: String? = "com.apple.Safari", muted: [String] = ["com.apple.Terminal"],
        mic: Bool = false, muteMic: Bool = true
    ) -> Bool {
        MuteRules.shouldPlay(
            enabled: enabled, frontmostBundleID: front, muted: muted, micInUse: mic, muteWhileMicInUse: muteMic)
    }
    #expect(play())
    #expect(!play(enabled: false))
    #expect(!play(front: "com.apple.Terminal"))
    #expect(!play(mic: true))
    #expect(play(mic: true, muteMic: false))
    #expect(play(front: nil))
}
