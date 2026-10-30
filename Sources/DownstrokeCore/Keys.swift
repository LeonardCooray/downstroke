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

/// Turns a flagsChanged event into a modifier press or release.
public enum ModifierTransition {
    public static let capsLock: UInt16 = 57

    /// true for a press, false for a release, nil when the key isn't a modifier or its state didn't change.
    public static func isPress(keyCode: UInt16, flags: UInt64, previousFlags: UInt64) -> Bool? {
        // Caps Lock sends one flagsChanged per physical press and has no device bit.
        if keyCode == capsLock { return true }
        guard let masks = masks(for: keyCode) else { return nil }
        let down = isDown(flags, masks)
        return down == isDown(previousFlags, masks) ? nil : down
    }

    private struct Masks {
        var device: UInt64
        var bothSides: UInt64
        var generic: UInt64
    }

    // Without either side's device bit, fall back to the device-independent mask.
    private static func isDown(_ flags: UInt64, _ m: Masks) -> Bool {
        flags & m.bothSides == 0 ? flags & m.generic != 0 : flags & m.device != 0
    }

    /// NX_DEVICE*KEYMASK bits from IOLLEvent.h tell left from right; the generic bits are CGEventFlags.
    private static func masks(for keyCode: UInt16) -> Masks? {
        let control: UInt64 = 0x0000_0001 | 0x0000_2000, shift: UInt64 = 0x0000_0002 | 0x0000_0004
        let command: UInt64 = 0x0000_0008 | 0x0000_0010, option: UInt64 = 0x0000_0020 | 0x0000_0040
        switch keyCode {
        case 59: return Masks(device: 0x0000_0001, bothSides: control, generic: 0x0004_0000) // left control
        case 62: return Masks(device: 0x0000_2000, bothSides: control, generic: 0x0004_0000) // right control
        case 56: return Masks(device: 0x0000_0002, bothSides: shift, generic: 0x0002_0000) // left shift
        case 60: return Masks(device: 0x0000_0004, bothSides: shift, generic: 0x0002_0000) // right shift
        case 55: return Masks(device: 0x0000_0008, bothSides: command, generic: 0x0010_0000) // left command
        case 54: return Masks(device: 0x0000_0010, bothSides: command, generic: 0x0010_0000) // right command
        case 58: return Masks(device: 0x0000_0020, bothSides: option, generic: 0x0008_0000) // left option
        case 61: return Masks(device: 0x0000_0040, bothSides: option, generic: 0x0008_0000) // right option
        case 63: return Masks(device: 0x0080_0000, bothSides: 0x0080_0000, generic: 0x0080_0000) // fn
        default: return nil
        }
    }
}
