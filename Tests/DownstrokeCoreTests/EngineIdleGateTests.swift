import DownstrokeCore
import Foundation
import Testing

@Test func pausesOnlyAfterTheTimeout() {
    let gate = EngineIdleGate(timeout: 60, now: 100)
    #expect(!gate.shouldPause(now: 159.9, activeVoices: 0))
    #expect(gate.shouldPause(now: 160, activeVoices: 0))
}

@Test func soundingVoicesHoldThePause() {
    let gate = EngineIdleGate(timeout: 1, now: 0)
    #expect(!gate.shouldPause(now: 10, activeVoices: 1))
    #expect(gate.shouldPause(now: 10, activeVoices: 0))
}

@Test func activityRestartsTheTimeout() {
    let gate = EngineIdleGate(timeout: 60, now: 0)
    #expect(!gate.noteActivity(now: 50))
    #expect(!gate.shouldPause(now: 100, activeVoices: 0))
    #expect(gate.shouldPause(now: 110, activeVoices: 0))
}

@Test func timeoutIsAdjustable() {
    let gate = EngineIdleGate(timeout: 60, now: 0)
    gate.timeout = 1
    #expect(gate.timeout == 1)
    #expect(gate.shouldPause(now: 1, activeVoices: 0))
    gate.timeout = .infinity
    #expect(!gate.shouldPause(now: 1e9, activeVoices: 0))
}

@Test func nonPositiveOrNaNTimeoutNeverPauses() {
    let gate = EngineIdleGate(timeout: .nan, now: 0)
    #expect(!gate.shouldPause(now: 1e9, activeVoices: 0))
    gate.timeout = 0
    #expect(!gate.shouldPause(now: 1e9, activeVoices: 0))
    gate.timeout = -5
    #expect(!gate.shouldPause(now: 1e9, activeVoices: 0))
}

@Test func parkedGateDoesNotPauseAgain() {
    let gate = EngineIdleGate(timeout: 1, now: 0)
    #expect(gate.park(now: 2))
    #expect(gate.isParked)
    #expect(!gate.shouldPause(now: 3, activeVoices: 0))
}

@Test func firstActivityAfterParkingWakesOnce() {
    let gate = EngineIdleGate(timeout: 1, now: 0)
    #expect(gate.park(now: 2))
    #expect(gate.noteActivity(now: 3))
    #expect(!gate.isParked)
    #expect(!gate.noteActivity(now: 3.1))
    #expect(gate.lastActivity == 3.1)
}

@Test func parkingBacksOffWhenActivityRacedIn() {
    let gate = EngineIdleGate(timeout: 1, now: 0)
    #expect(gate.shouldPause(now: 2, activeVoices: 0))
    _ = gate.noteActivity(now: 2)
    #expect(!gate.park(now: 2))
    #expect(!gate.isParked)
}

@Test func unparkAndRepark() {
    let gate = EngineIdleGate(timeout: 1, now: 0)
    #expect(gate.park(now: 2))
    gate.unpark()
    #expect(!gate.isParked)
    #expect(!gate.noteActivity(now: 3))
    gate.repark()
    #expect(gate.isParked)
    #expect(gate.noteActivity(now: 4))
}

@Test func concurrentActivityWakesExactlyOnce() async {
    for _ in 0..<50 {
        let gate = EngineIdleGate(timeout: 1, now: 0)
        #expect(gate.park(now: 5))
        let wakes = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<8 { group.addTask { gate.noteActivity(now: 6 + Double(i)) } }
            var count = 0
            for await woke in group where woke { count += 1 }
            return count
        }
        #expect(wakes == 1)
    }
}
