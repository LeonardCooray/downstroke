@testable import DownstrokeCore
import Foundation
import Testing

private func withSuite(_ body: (UserDefaults, String) throws -> Void) rethrows {
    let name = "com.leonardcooray.downstroke.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults, name)
}

@Test func settingsDefaultsAndRoundTrip() {
    withSuite { defaults, _ in
        let store = SettingsStore(defaults: defaults)
        let s = store.settings
        #expect(s.enabled)
        #expect(s.volume == 0.68)
        #expect(s.boardID == "holy-panda")
        #expect(s.hitStrengthEnabled)
        #expect(s.sensitivity == 0.5)
        #expect(s.keyUpSounds)
        #expect(s.stereoWidth == 0.5)
        #expect(s.mutedBundleIDs.isEmpty)
        #expect(s.muteWhileMicInUse)
        #expect(!s.launchAtLogin)
        #expect(s.hotkey == Hotkey(keyCode: 40, modifiers: Hotkey.control | Hotkey.option | Hotkey.command))
        #expect(s.hotkey.displayString == "⌃⌥⌘K")

        store.settings.volume = 0.25
        store.settings.mutedBundleIDs = ["com.apple.Terminal"]
        store.settings.boardID = "other"
        store.save()
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.volume == 0.25)
    }
}

@Test func corruptSettingsFallBackToDefaults() {
    withSuite { defaults, _ in
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings == DownstrokeSettings())
        defaults.set("a string", forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings == DownstrokeSettings())
        defaults.set(Data(#"{"volume":"loud"}"#.utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings == DownstrokeSettings())
    }
}

@Test func missingKeysKeepTheirDefaults() {
    withSuite { defaults, _ in
        defaults.set(Data(#"{"volume":0.3,"someFutureKey":true}"#.utf8), forKey: "settings.v1")
        var expected = DownstrokeSettings()
        expected.volume = 0.3
        #expect(SettingsStore(defaults: defaults).settings == expected)
    }
}

@Test func settingsLandInTheGivenSuite() {
    withSuite { defaults, name in
        let store = SettingsStore(defaults: defaults)
        store.settings.volume = 0.11
        store.save()
        #expect(defaults.persistentDomain(forName: name)?["settings.v1"] != nil)
    }
}

@Test func slamAccentDefaultsOnButASavedOffStaysOff() {
    withSuite { defaults, _ in
        defaults.set(Data("{}".utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings.hitStrengthEnabled)
        defaults.set(Data(#"{"hitStrengthEnabled":false}"#.utf8), forKey: "settings.v1")
        #expect(!SettingsStore(defaults: defaults).settings.hitStrengthEnabled)
    }
}
