import Synchronization

/// One sound to start; plain values and raw pointers only, so copying it never retains anything.
public struct Trigger: Sendable {
    public var clip: ClipRef
    public var gain: Float
    /// -1 is hard left, 1 hard right.
    public var pan: Float
    public var rate: Float
    public var eventTime: Double
    /// The tag of the bank that owns `clip`.
    public var bankTag: Int

    public init(clip: ClipRef, gain: Float, pan: Float, rate: Float, eventTime: Double, bankTag: Int) {
        self.clip = clip
        self.gain = gain
        self.pan = pan
        self.rate = rate
        self.eventTime = eventTime
        self.bankTag = bankTag
    }
}

/// Bounded FIFO from any thread to the render thread.
// Producers serialise on the mutex; the one consumer uses atomics only.
public final class TriggerQueue: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<Trigger>
    private let capacity: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let producers = Mutex(())

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots = .allocate(capacity: capacity)
    }

    deinit { slots.deallocate() }

    /// False when full. Any thread.
    public func push(_ trigger: Trigger) -> Bool {
        producers.withLock { _ in
            let end = tail.load(ordering: .relaxed)
            guard end - head.load(ordering: .acquiring) < capacity else { return false }
            (slots + end % capacity).initialize(to: trigger)
            tail.store(end + 1, ordering: .releasing)
            return true
        }
    }

    /// Render thread only.
    public func pop() -> Trigger? {
        let start = head.load(ordering: .relaxed)
        guard start != tail.load(ordering: .acquiring) else { return nil }
        let trigger = slots[start % capacity]
        head.store(start + 1, ordering: .releasing)
        return trigger
    }
}
