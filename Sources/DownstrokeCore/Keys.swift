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

/// Physical key groups, the unit a sound pack records samples for.
public enum KeyGroup: String, CaseIterable, Sendable {
    case alpha, number, space, enter, backspace, tab, modifier, arrow, function, escape, punctuation, other
}

/// Maps ANSI virtual key codes to key groups.
public enum KeyClassifier {
    public static func group(for keyCode: UInt16) -> KeyGroup {
        switch keyCode {
        case 0...9, 11...17, 31, 32, 34, 35, 37, 38, 40, 45, 46: return .alpha
        case 18...23, 25, 26, 28, 29, 82...89, 91, 92: return .number
        case 49: return .space
        case 36, 76: return .enter
        case 51, 117: return .backspace
        case 48: return .tab
        case 54...63: return .modifier
        case 123...126: return .arrow
        case 53: return .escape
        case 96...101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122: return .function
        case 10, 24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50: return .punctuation
        default: return .other
        }
    }
}

/// Horizontal key position on an ANSI MacBook keyboard, for stereo panning.
public enum KeyLayout {
    /// 0 is the left edge, 1 the right edge; 0.5 for keys not on the keyboard.
    public static func position(for keyCode: UInt16) -> Float {
        centres[keyCode] ?? 0.5
    }

    private static let width: Float = 15

    // Each row lists (key code, width in key units) left to right, with every row 15 units wide.
    private static let rows: [[(UInt16, Float)]] = [
        [(53, 1.5), (122, 1), (120, 1), (99, 1), (118, 1), (96, 1), (97, 1), (98, 1), (100, 1), (101, 1), (109, 1), (103, 1), (111, 1), (117, 1.5)],
        [(50, 1), (18, 1), (19, 1), (20, 1), (21, 1), (23, 1), (22, 1), (26, 1), (28, 1), (25, 1), (29, 1), (27, 1), (24, 1), (51, 2)],
        [(48, 1.5), (12, 1), (13, 1), (14, 1), (15, 1), (17, 1), (16, 1), (32, 1), (34, 1), (31, 1), (35, 1), (33, 1), (30, 1), (42, 1.5)],
        [(57, 1.75), (0, 1), (1, 1), (2, 1), (3, 1), (5, 1), (4, 1), (38, 1), (40, 1), (37, 1), (41, 1), (39, 1), (36, 2.25)],
        [(56, 2.25), (6, 1), (7, 1), (8, 1), (9, 1), (11, 1), (45, 1), (46, 1), (43, 1), (47, 1), (44, 1), (60, 2.75)],
        [(63, 1), (59, 1), (58, 1), (55, 1.5), (49, 5), (54, 1.5), (61, 1), (123, 1), (125, 1), (124, 1)],
    ]

    private static let centres: [UInt16: Float] = {
        var result: [UInt16: Float] = [:]
        for row in rows {
            var left: Float = 0
            for (code, keyWidth) in row {
                result[code] = (left + keyWidth / 2) / width
                left += keyWidth
            }
        }
        return result
    }()
}
