import DownstrokeCore
import Testing

private let shiftGeneric: UInt64 = 0x0002_0000
private let leftShift: UInt64 = shiftGeneric | 0x0000_0002
private let rightShift: UInt64 = shiftGeneric | 0x0000_0004
private let commandGeneric: UInt64 = 0x0010_0000
private let optionGeneric: UInt64 = 0x0008_0000

private func isPress(_ code: UInt16, _ flags: UInt64, after previous: UInt64) -> Bool? {
    ModifierTransition.isPress(keyCode: code, flags: flags, previousFlags: previous)
}

@Test func leftShiftDownThenUp() {
    #expect(isPress(56, leftShift, after: 0) == true)
    #expect(isPress(56, 0, after: leftShift) == false)
}

@Test func rightShiftWhileLeftHeldIsToldApartByDeviceBits() {
    let both = leftShift | rightShift
    #expect(isPress(60, both, after: leftShift) == true)
    #expect(isPress(60, leftShift, after: both) == false)
    #expect(isPress(56, rightShift, after: both) == false)
}

@Test func leftAndRightCommandAndOption() {
    let leftCommand = commandGeneric | 0x08, rightCommand = commandGeneric | 0x10
    let leftOption = optionGeneric | 0x20, rightOption = optionGeneric | 0x40
    #expect(isPress(55, leftCommand, after: 0) == true)
    #expect(isPress(54, leftCommand | rightCommand, after: leftCommand) == true)
    #expect(isPress(55, rightCommand, after: leftCommand | rightCommand) == false)
    #expect(isPress(54, 0, after: rightCommand) == false)
    #expect(isPress(58, leftOption, after: 0) == true)
    #expect(isPress(61, leftOption | rightOption, after: leftOption) == true)
    #expect(isPress(61, leftOption, after: leftOption | rightOption) == false)
    #expect(isPress(58, 0, after: leftOption) == false)
}

@Test func capsLockAlwaysCountsAsPress() {
    let capsOn: UInt64 = 0x0001_0000
    #expect(isPress(ModifierTransition.capsLock, capsOn, after: 0) == true)
    #expect(isPress(ModifierTransition.capsLock, 0, after: capsOn) == true)
}

@Test func missingDeviceBitsFallBackToGenericFlag() {
    #expect(isPress(56, shiftGeneric, after: 0) == true)
    #expect(isPress(56, 0, after: shiftGeneric) == false)
    #expect(isPress(60, shiftGeneric, after: 0) == true)
}

@Test func unchangedStateOrNonModifierIsIgnored() {
    #expect(isPress(56, leftShift, after: leftShift) == nil)
    #expect(isPress(0, leftShift, after: 0) == nil)
}

@Test func classifiesKeys() {
    let expected: [(UInt16, KeyGroup)] = [
        (0, .alpha), (49, .space), (36, .enter), (51, .backspace), (48, .tab), (56, .modifier),
        (123, .arrow), (122, .function), (53, .escape), (18, .number), (43, .punctuation), (200, .other),
    ]
    for (code, group) in expected {
        #expect(KeyClassifier.group(for: code) == group, "key code \(code)")
    }
}

@Test func layoutPositions() {
    #expect(KeyLayout.position(for: 50) < 0.1)
    #expect(KeyLayout.position(for: 42) > 0.9)
    #expect((0.45...0.55).contains(KeyLayout.position(for: 49)))
    #expect(KeyLayout.position(for: 0) < KeyLayout.position(for: 9))
    #expect(KeyLayout.position(for: 9) < KeyLayout.position(for: 37))
    #expect(KeyLayout.position(for: 200) == 0.5)
}

@Test func layoutPositionsStayInRange() {
    for code in UInt16(0)...255 {
        #expect((0...1).contains(KeyLayout.position(for: code)), "key code \(code)")
    }
}

@Test func twentySixKeysAreAlpha() {
    #expect((UInt16(0)...255).filter { KeyClassifier.group(for: $0) == .alpha }.count == 26)
}
