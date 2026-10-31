@testable import DownstrokeCore
import Foundation
import Testing

private func trigger(_ clip: ClipRef, time: Double, tag: Int = 1) -> Trigger {
    Trigger(clip: clip, gain: 1, pan: 0, rate: 1, eventTime: time, bankTag: tag)
}

@Test func queueIsFIFOAndBounded() {
    let clip = makeClip([0])
    defer { freeClip(clip) }
    let queue = TriggerQueue()
    for i in 0..<256 { #expect(queue.push(trigger(clip, time: Double(i)))) }
    #expect(!queue.push(trigger(clip, time: 999)))
    for i in 0..<256 { #expect(queue.pop()?.eventTime == Double(i)) }
    #expect(queue.pop() == nil)
    // Wraps around once drained.
    for i in 0..<10 { #expect(queue.push(trigger(clip, time: Double(1000 + i)))) }
    for i in 0..<10 { #expect(queue.pop()?.eventTime == Double(1000 + i)) }
    #expect(queue.pop() == nil)
}

@Test func queueSurvivesConcurrentProducers() {
    let clip = makeClip([0])
    defer { freeClip(clip) }
    let queue = TriggerQueue()
    for p in 0..<4 {
        Thread {
            for i in 0..<1000 {
                let t = trigger(clip, time: Double(p * 1000 + i), tag: p)
                while !queue.push(t) { sched_yield() }
            }
        }.start()
    }
    var seen = Set<Int>()
    var duplicates = 0, outOfOrder = 0
    var last = [Int](repeating: -1, count: 4)
    let deadline = Date().addingTimeInterval(20)
    while seen.count + duplicates < 4000, Date() < deadline {
        guard let t = queue.pop() else { sched_yield(); continue }
        let id = Int(t.eventTime)
        if !seen.insert(id).inserted { duplicates += 1 }
        if id % 1000 <= last[t.bankTag] { outOfOrder += 1 }
        last[t.bankTag] = id % 1000
    }
    #expect(seen.count == 4000)
    #expect(duplicates == 0)
    #expect(outOfOrder == 0)
    #expect(queue.pop() == nil)
}
