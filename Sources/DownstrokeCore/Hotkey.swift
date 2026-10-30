// Virtual key codes from Carbon's Events.h (ANSI layout).
public enum KeyCode {
    public static let a: UInt32 = 0, k: UInt32 = 40, s: UInt32 = 1, d: UInt32 = 2, c: UInt32 = 8, z: UInt32 = 6
    public static let one: UInt32 = 18, two: UInt32 = 19, three: UInt32 = 20, four: UInt32 = 21
    public static let five: UInt32 = 23, six: UInt32 = 22
    public static let returnKey: UInt32 = 36, delete: UInt32 = 51, escape: UInt32 = 53, forwardDelete: UInt32 = 117

    static let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
        7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public static let defaultToggle = Hotkey(keyCode: KeyCode.k, modifiers: control | option | command)

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    public var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + (KeyCode.names[keyCode] ?? "Key \(keyCode)")
    }

    // Needs ⌃, ⌥ or ⌘: plain or Shift-only keys would take over typing everywhere.
    public var isUsableGlobally: Bool {
        modifiers & (Self.control | Self.option | Self.command) != 0 && !isReservedBySystem
    }

    public var isReservedBySystem: Bool {
        modifiers == Self.shift | Self.command
            && [KeyCode.three, KeyCode.four, KeyCode.five, KeyCode.six].contains(keyCode)
    }
}
