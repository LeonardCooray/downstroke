/// One physical key press or release, stamped on the MonotonicClock timebase.
public struct KeyEvent: Sendable, Equatable {
    public var time: Double
    public var keyCode: UInt16
    public var isRelease: Bool
    public var isModifier: Bool

    public init(time: Double, keyCode: UInt16, isRelease: Bool, isModifier: Bool) {
        self.time = time
        self.keyCode = keyCode
        self.isRelease = isRelease
        self.isModifier = isModifier
    }
}
