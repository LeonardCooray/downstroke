@testable import DownstrokeCore
import Foundation
import Testing

private func press(_ code: UInt16 = 0, at time: Double) -> KeyEvent {
    KeyEvent(time: time, keyCode: code, isRelease: false, isModifier: false)
}

private func release(_ code: UInt16 = 0, at time: Double) -> KeyEvent {
    KeyEvent(time: time, keyCode: code, isRelease: true, isModifier: false)
}

private struct Rig {
    var pipeline: TypingPipeline
    var queue = TriggerQueue()
    var ring: SampleRing

    init(settings: DownstrokeSettings = DownstrokeSettings(), sensorAvailable: Bool = true, bank: SampleBank = sharedBank) {
        let queue = TriggerQueue()
        let ring = SampleRing()
        pipeline = TypingPipeline(queue: queue, ring: ring, random: SeededRandom(state: 5))
        self.queue = queue
        self.ring = ring
        pipeline.update(settings: settings, bank: bank, sensorAvailable: sensorAvailable)
        pipeline.setContext(frontmostBundleID: nil, micInUse: false)
    }

    func slots(group: KeyGroup = .alpha) -> [Slot] { drain(queue).map { slot(of: $0, in: sharedBank, group: group) } }
}

@Test func waitsForWindowWhenSensing() {
    let rig = Rig()
    rig.ring.append(time: 1.0, impact: 0.06)
    rig.ring.append(time: 1.009, impact: 0.001)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.tick(now: 1.007)
    #expect(rig.slots().isEmpty)
    rig.pipeline.tick(now: 1.0081)
    #expect(rig.slots() == [.press(.slam)])
}

@Test func stalledSensorFlushesAtFixedStrength() {
    let rig = Rig()
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.tick(now: 1.0081)
    #expect(rig.slots().isEmpty)
    rig.pipeline.tick(now: 1.0121)
    #expect(rig.slots() == [.press(.medium), .press(.hard)])
    rig.pipeline.tick(now: 1.02)
    #expect(rig.slots().isEmpty)
}

@Test func bumpWindowFallsBackToFixedStrength() {
    let rig = Rig()
    rig.ring.append(time: 1.0, impact: 0.9)
    rig.ring.append(time: 1.009, impact: 0.9)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.tick(now: 1.0081)
    #expect(rig.slots() == [.press(.medium), .press(.hard)])
}

@Test func lateKeyEventResolvesWithoutATick() {
    let rig = Rig()
    rig.ring.append(time: 1.0, impact: 0.06)
    rig.ring.append(time: 1.009, impact: 0.001)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.01)
    #expect(rig.slots() == [.press(.slam)])
}

@Test func immediateWhenSensingOff() {
    var settings = DownstrokeSettings()
    settings.hitStrengthEnabled = false
    let off = Rig(settings: settings)
    off.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    #expect(off.slots() == [.press(.medium), .press(.hard)])

    let unavailable = Rig(sensorAvailable: false)
    unavailable.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    #expect(unavailable.slots() == [.press(.medium), .press(.hard)])
}

@Test func releaseFollowsPendingPress() {
    let rig = Rig()
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.keyEvent(release(at: 1.004), now: 1.004)
    #expect(rig.slots().isEmpty)
    rig.pipeline.tick(now: 1.0121)
    let out = drain(rig.queue)
    #expect(out.map { slot(of: $0, in: sharedBank) } == [.press(.medium), .press(.hard), .release])
    #expect(out.map(\.eventTime) == [1.0, 1.0, 1.004])
}

@Test func releaseWithNothingPendingPlaysAtOnce() {
    let rig = Rig()
    rig.pipeline.keyEvent(release(at: 1.0), now: 1.0)
    #expect(rig.slots() == [.release])
}

@Test func mutedOrDisabledDropsEverything() {
    var settings = DownstrokeSettings()
    settings.mutedBundleIDs = ["com.apple.Terminal"]
    var rig = Rig(settings: settings, sensorAvailable: false)
    rig.pipeline.setContext(frontmostBundleID: "com.apple.Terminal", micInUse: false)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.keyEvent(release(at: 1.1), now: 1.1)
    #expect(rig.slots().isEmpty)

    rig.pipeline.setContext(frontmostBundleID: nil, micInUse: true)
    rig.pipeline.keyEvent(press(at: 2.0), now: 2.0)
    #expect(rig.slots().isEmpty)

    rig.pipeline.setContext(frontmostBundleID: nil, micInUse: false)
    rig.pipeline.keyEvent(press(at: 3.0), now: 3.0)
    #expect(!rig.slots().isEmpty)

    settings.enabled = false
    rig.pipeline.update(settings: settings, bank: sharedBank, sensorAvailable: false)
    rig.pipeline.keyEvent(press(at: 4.0), now: 4.0)
    #expect(rig.slots().isEmpty)
    rig = Rig(sensorAvailable: false)
}

@Test func disablingSensingFlushesPendingPress() {
    var settings = DownstrokeSettings()
    let rig = Rig(settings: settings)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    settings.hitStrengthEnabled = false
    rig.pipeline.update(settings: settings, bank: sharedBank, sensorAvailable: true)
    #expect(rig.slots() == [.press(.medium), .press(.hard)])
}

@Test func noBankYetDropsKeys() {
    let queue = TriggerQueue()
    let pipeline = TypingPipeline(queue: queue, ring: nil)
    pipeline.keyEvent(press(at: 1.0), now: 1.0)
    pipeline.tick(now: 2.0)
    #expect(drain(queue).isEmpty)
}

@Test func nilRingPlaysImmediately() {
    let queue = TriggerQueue()
    let pipeline = TypingPipeline(queue: queue, ring: nil)
    pipeline.update(settings: DownstrokeSettings(), bank: sharedBank, sensorAvailable: true)
    pipeline.keyEvent(press(at: 1.0), now: 1.0)
    #expect(drain(queue).count == 2)
}

@Test func triggersCarryTheCurrentBanksTag() throws {
    let rig = Rig(sensorAvailable: false)
    let other = try SampleBank(board: vendoredBoard("holy-panda"), sampleRate: 48000)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.update(settings: DownstrokeSettings(), bank: other, sensorAvailable: false)
    rig.pipeline.keyEvent(press(at: 2.0), now: 2.0)
    let out = drain(rig.queue)
    #expect(out.prefix(2).allSatisfy { $0.bankTag == sharedBank.tag })
    #expect(out.suffix(2).allSatisfy { $0.bankTag == other.tag })
}

@Test func auditionIgnoresMuteRulesAndEnabled() throws {
    var settings = DownstrokeSettings()
    settings.enabled = false
    settings.stereoWidth = 1
    let rig = Rig(settings: settings)
    rig.pipeline.setContext(frontmostBundleID: nil, micInUse: true)
    let before = MonotonicClock.now()
    rig.pipeline.audition(boardBank: sharedBank)
    let out = drain(rig.queue)
    let t = try #require(out.first)
    #expect(out.count == 1)
    #expect(slot(of: t, in: sharedBank) == .press(.hard))
    #expect(t.pan == 0)
    #expect(t.bankTag == sharedBank.tag)
    #expect(t.eventTime >= before)
}

@Test func tickIsCheapAndSafeWhenIdle() {
    let rig = Rig()
    for i in 0..<10_000 { rig.pipeline.tick(now: Double(i) * 0.00125) }
    #expect(drain(rig.queue).isEmpty)
}

@Test func survivesConcurrentCallers() {
    let rig = Rig()
    let group = DispatchGroup()
    for worker in 0..<3 {
        group.enter()
        Thread {
            defer { group.leave() }
            for i in 0..<2000 {
                let t = 1.0 + Double(i) * 0.001
                switch worker {
                case 0: rig.pipeline.keyEvent(press(at: t), now: t)
                case 1: rig.pipeline.tick(now: t)
                default: rig.pipeline.update(settings: DownstrokeSettings(), bank: sharedBank, sensorAvailable: i % 2 == 0)
                }
                // One consumer only.
                if worker == 1, i % 50 == 0 { _ = drain(rig.queue) }
            }
        }.start()
    }
    group.wait()
}

@Test func hasPendingTracksWaitingPresses() {
    let rig = Rig()
    #expect(!rig.pipeline.hasPending)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    #expect(rig.pipeline.hasPending)
    rig.pipeline.tick(now: 1.0121)
    #expect(!rig.pipeline.hasPending)
}

@Test func lastVelocityFollowsPlayedPresses() {
    let rig = Rig(sensorAvailable: false)
    #expect(rig.pipeline.lastVelocity == nil)
    rig.pipeline.keyEvent(release(at: 1.0), now: 1.0)
    #expect(rig.pipeline.lastVelocity == nil)
    rig.pipeline.keyEvent(press(at: 1.1), now: 1.1)
    #expect(rig.pipeline.lastVelocity == 0.5)
}

@Test func lastPressCountsEveryPlayedPressEvenAtTheSameVelocity() {
    let rig = Rig(sensorAvailable: false)
    #expect(rig.pipeline.lastPress.count == 0)
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    rig.pipeline.keyEvent(release(at: 1.05), now: 1.05)
    rig.pipeline.keyEvent(press(at: 1.1), now: 1.1)
    #expect(rig.pipeline.lastPress.count == 2)
    #expect(rig.pipeline.lastPress.velocity == 0.5)
}

@Test func turningSensingOffFlushesAndClearsPending() {
    let rig = Rig()
    rig.pipeline.keyEvent(press(at: 1.0), now: 1.0)
    #expect(rig.pipeline.hasPending)
    rig.pipeline.update(settings: DownstrokeSettings(), bank: sharedBank, sensorAvailable: false)
    #expect(!rig.pipeline.hasPending)
    #expect(rig.slots() == [.press(.medium), .press(.hard)])
}

@Test func exposesLatestSettings() {
    var settings = DownstrokeSettings()
    settings.sensitivity = 0.8
    settings.mutedBundleIDs = ["com.example.app"]
    let rig = Rig(settings: settings)
    #expect(rig.pipeline.settings == settings)
}
