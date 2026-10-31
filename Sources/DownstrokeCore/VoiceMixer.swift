import Foundation
import Synchronization

private let idleTag = Int.min
// Triggers older than this at render time are dropped, so an engine outage never replays a burst.
private let staleAfter = 0.25

private struct Voice {
    var clip: ClipRef?
    var position: Double = 0
    var rate: Double = 1
    var gainLeft: Float = 0
    var gainRight: Float = 0
    var order: UInt64 = 0
    var tag: Int = idleTag
}

private struct RenderState {
    var sampleRate: Double = 0
    var rampLength = 1
    var releaseCoefficient: Float = 0
    var gain: Float = 1
    var rampTarget: Float = 1
    var rampStep: Float = 0
    var rampRemaining = 0
    var envelope: Float = 0
    var nextOrder: UInt64 = 0
}

/// Single-producer single-consumer ring of Doubles.
private struct DoubleRing: ~Copyable {
    let buffer: UnsafeMutablePointer<Double>
    let capacity: Int
    let head = Atomic<Int>(0)
    let tail = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
    }

    deinit { buffer.deallocate() }

    func push(_ value: Double) {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else { return }
        buffer[end % capacity] = value
        tail.store(end + 1, ordering: .releasing)
    }

    func pop() -> Double? {
        let start = head.load(ordering: .relaxed)
        guard start != tail.load(ordering: .acquiring) else { return nil }
        let value = buffer[start % capacity]
        head.store(start + 1, ordering: .releasing)
        return value
    }
}

/// Mixes preloaded clips on the render thread; everything it touches there is preallocated.
// Render state sits behind raw pointers, shared state is atomic, `retired` is main-thread only.
public final class VoiceMixer: @unchecked Sendable {
    private let queue: TriggerQueue
    private let maxVoices: Int
    private let voices: UnsafeMutablePointer<Voice>
    private let state: UnsafeMutablePointer<RenderState>
    // Each voice slot's bank tag, published for retirement checks.
    private let slotTags: UnsafeMutablePointer<Atomic<Int>>
    private let cycles = Atomic<Int>(0)
    private let activeCount = Atomic<Int>(0)
    private let staleCount = Atomic<Int>(0)
    private let targetGain = Atomic<UInt32>(Float(1).bitPattern)
    private let sampleRateBits = Atomic<UInt64>(Double(48000).bitPattern)
    // Triggers at or after this event time skip the stale guard; infinity means none do.
    private let wakeMarkBits = Atomic<UInt64>(Double.infinity.bitPattern)
    private let latencies = DoubleRing(capacity: 1024)
    private var retired: [(bank: SampleBank, deadline: Double, deadlineCycle: Int?)] = []

    public init(queue: TriggerQueue, maxVoices: Int = 48) {
        precondition(maxVoices > 0)
        self.queue = queue
        self.maxVoices = maxVoices
        voices = .allocate(capacity: maxVoices)
        voices.initialize(repeating: Voice(), count: maxVoices)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState())
        slotTags = .allocate(capacity: maxVoices)
        for i in 0..<maxVoices { (slotTags + i).initialize(to: Atomic(idleTag)) }
    }

    deinit {
        voices.deallocate()
        state.deallocate()
        slotTags.deinitialize(count: maxVoices)
        slotTags.deallocate()
    }

    /// Voices sounding at the end of the last render.
    public var activeVoices: Int { activeCount.load(ordering: .relaxed) }

    /// Triggers dropped for being more than 0.25 s old when popped (and older than any wake mark).
    public var staleTriggers: Int { staleCount.load(ordering: .relaxed) }

    /// Any thread. Triggers from `eventTime` on play however late the engine restarts.
    public func setWakeMark(_ eventTime: Double) {
        guard eventTime.isFinite else { return }
        wakeMarkBits.store(eventTime.bitPattern, ordering: .releasing)
    }

    /// Main thread, once the restarted engine has rendered.
    public func clearWakeMark() { wakeMarkBits.store(Double.infinity.bitPattern, ordering: .releasing) }

    public var hasWakeMark: Bool { wakeMarkBits.load(ordering: .acquiring) != Double.infinity.bitPattern }

    /// Clamped to 0...4; non-finite values are ignored.
    public func setMasterGain(_ g: Float) {
        guard g.isFinite else { return }
        targetGain.store(min(max(g, 0), 4).bitPattern, ordering: .relaxed)
    }

    /// Only changes time constants; clips must already be at this rate. Rates outside 8 kHz...768 kHz are ignored.
    public func setSampleRate(_ sr: Double) {
        guard sr.isFinite, (8000...768_000).contains(sr) else { return }
        sampleRateBits.store(sr.bitPattern, ordering: .relaxed)
    }

    /// Render thread only. Overwrites `frames` samples of each output buffer.
    public func render(frames: Int, hostTime: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let sampleRate = Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
        if sampleRate != state.pointee.sampleRate {
            state.pointee.sampleRate = sampleRate
            state.pointee.rampLength = max(1, Int((0.010 * sampleRate).rounded()))
            state.pointee.releaseCoefficient = Float(exp(-1 / (0.050 * sampleRate)))
        }
        let target = Float(bitPattern: targetGain.load(ordering: .relaxed))
        if target != state.pointee.rampTarget {
            state.pointee.rampTarget = target
            state.pointee.rampRemaining = state.pointee.rampLength
            state.pointee.rampStep = (target - state.pointee.gain) / Float(state.pointee.rampLength)
        }

        let wakeMark = Double(bitPattern: wakeMarkBits.load(ordering: .acquiring))
        while let trigger = queue.pop() {
            if hostTime - trigger.eventTime > staleAfter && trigger.eventTime < wakeMark {
                staleCount.wrappingAdd(1, ordering: .relaxed)
                continue
            }
            start(trigger, hostTime: hostTime)
        }

        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        var active = 0
        for v in 0..<maxVoices where voices[v].clip != nil {
            if mix(voice: v, frames: frames, left: left, right: right) { active += 1 }
        }
        finish(frames: frames, left: left, right: right)

        activeCount.store(active, ordering: .relaxed)
        cycles.wrappingAdd(1, ordering: .releasing)
    }

    /// Main thread. Appends every latency recorded since the last drain.
    public func drainLatencies(into values: inout [Double]) {
        while let value = latencies.pop() { values.append(value) }
    }

    /// Main thread. Producers must not push for `bank` later than `seconds` after swapping it out.
    public func retire(_ bank: SampleBank, after seconds: Double = 2) {
        retired.append((bank, MonotonicClock.now() + seconds, nil))
        collectRetired(now: MonotonicClock.now())
    }

    /// Main thread. Frees retired banks past their deadline that no voice or queued trigger can still read.
    public func collectRetired(now: Double) {
        guard !retired.isEmpty else { return }
        let cycle = cycles.load(ordering: .acquiring)
        for i in retired.indices where retired[i].deadlineCycle == nil && now >= retired[i].deadline {
            retired[i].deadlineCycle = cycle
        }
        // Two finished renders after the deadline means everything pushed before it has been popped.
        retired.removeAll { entry in
            guard let marked = entry.deadlineCycle else { return false }
            return cycle &- marked >= 2 && !tagInUse(entry.bank.tag)
        }
    }

    private func tagInUse(_ tag: Int) -> Bool {
        (0..<maxVoices).contains { slotTags[$0].load(ordering: .relaxed) == tag }
    }

    private func start(_ trigger: Trigger, hostTime: Double) {
        guard trigger.clip.frames > 0, trigger.rate > 0, trigger.rate.isFinite,
              trigger.gain.isFinite, trigger.pan.isFinite else { return }
        var slot = -1, oldest = 0
        for v in 0..<maxVoices {
            if voices[v].clip == nil { slot = v; break }
            if voices[v].order < voices[oldest].order { oldest = v }
        }
        if slot < 0 { slot = oldest }
        let angle = (Double(min(max(trigger.pan, -1), 1)) + 1) * .pi / 4
        voices[slot] = Voice(
            clip: trigger.clip, position: 0, rate: min(Double(trigger.rate), 64),
            gainLeft: trigger.gain * Float(cos(angle)), gainRight: trigger.gain * Float(sin(angle)),
            order: state.pointee.nextOrder, tag: trigger.bankTag
        )
        state.pointee.nextOrder &+= 1
        slotTags[slot].store(trigger.bankTag, ordering: .relaxed)
        if trigger.recordsLatency { latencies.push(hostTime - trigger.eventTime) }
    }

    /// Adds one voice into the outputs; false once it has ended.
    private func mix(voice v: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        guard let clip = voices[v].clip else { return false }
        let n = clip.frames, rate = voices[v].rate
        let gl = voices[v].gainLeft, gr = voices[v].gainRight
        let source = clip.left
        var position = voices[v].position
        var i = 0
        if let sourceRight = clip.right {
            // Stereo keeps the mono pan law so mono and stereo packs match at centre.
            while i < frames {
                let index = Int(position)
                if index >= n { break }
                let frac = Float(position - Double(index))
                let next = index + 1 < n
                let l0 = source[index], r0 = sourceRight[index]
                let l1 = next ? source[index + 1] : 0, r1 = next ? sourceRight[index + 1] : 0
                left[i] += (l0 + (l1 - l0) * frac) * gl
                right[i] += (r0 + (r1 - r0) * frac) * gr
                position += rate
                i += 1
            }
        } else {
            while i < frames {
                let index = Int(position)
                if index >= n { break }
                let frac = Float(position - Double(index))
                let s0 = source[index]
                let s1 = index + 1 < n ? source[index + 1] : 0
                let s = s0 + (s1 - s0) * frac
                left[i] += s * gl
                right[i] += s * gr
                position += rate
                i += 1
            }
        }
        if Int(position) >= n {
            voices[v].clip = nil
            voices[v].tag = idleTag
            slotTags[v].store(idleTag, ordering: .relaxed)
            return false
        }
        voices[v].position = position
        return true
    }

    /// Master gain ramp, then an instant-attack peak limiter.
    private func finish(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var s = state.pointee
        for i in 0..<frames {
            if s.rampRemaining > 0 {
                s.rampRemaining -= 1
                s.gain = s.rampRemaining == 0 ? s.rampTarget : s.gain + s.rampStep
            }
            var l = left[i] * s.gain, r = right[i] * s.gain
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            if !s.envelope.isFinite { s.envelope = 0 }
            s.envelope = max(max(abs(l), abs(r)), s.envelope * s.releaseCoefficient)
            if s.envelope > 1 {
                let g = 1 / s.envelope
                l *= g
                r *= g
            }
            left[i] = min(max(l, -1), 1)
            right[i] = min(max(r, -1), 1)
        }
        state.pointee = s
    }
}
