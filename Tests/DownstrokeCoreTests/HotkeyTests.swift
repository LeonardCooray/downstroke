@testable import DownstrokeCore
import Testing

@Test func hotkeyProblems() {
    #expect(Hotkey.defaultToggle.problem == nil)
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.control | Hotkey.shift).problem == nil)
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.option | Hotkey.command).problem == nil)
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.option | Hotkey.control).problem == nil)
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.option).problem == "Add ⌃ or ⌘ so ⌥ still types special characters")
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.option | Hotkey.shift).problem == "Add ⌃ or ⌘ so ⌥ still types special characters")
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: 0).problem == "Add ⌃ or ⌘")
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.shift).problem == "Add ⌃ or ⌘")
    #expect(Hotkey(keyCode: KeyCode.c, modifiers: Hotkey.command).problem == "Add ⌃ or ⌥ so apps keep their ⌘ shortcuts")
    #expect(Hotkey(keyCode: KeyCode.k, modifiers: Hotkey.command | Hotkey.shift).problem == "Add ⌃ or ⌥ so apps keep their ⌘ shortcuts")
    #expect(Hotkey(keyCode: KeyCode.four, modifiers: Hotkey.command | Hotkey.shift).problem == "⇧⌘4 is reserved by macOS")
}

@Test func sampleRingCountsAppends() {
    let ring = SampleRing(capacity: 4)
    #expect(ring.count == 0)
    for i in 0..<6 { ring.append(time: Double(i), impact: 0) }
    #expect(ring.count == 6)
}
