import Foundation

public struct DownstrokeSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var volume: Float = 0.68
    public var boardID = "holy-panda"
    public var hitStrengthEnabled = true
    public var sensitivity: Float = 0.5
    public var keyUpSounds = true
    public var stereoWidth: Float = 0.5
    public var mutedBundleIDs: [String] = []
    public var muteWhileMicInUse = true
    public var launchAtLogin = false
    public var hotkey = Hotkey.defaultToggle
    public var slamAccentVersion = 1

    public init() {}

    // Keys missing from older saves keep their defaults; wrong types still throw.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? volume
        boardID = try c.decodeIfPresent(String.self, forKey: .boardID) ?? boardID
        hitStrengthEnabled = try c.decodeIfPresent(Bool.self, forKey: .hitStrengthEnabled) ?? hitStrengthEnabled
        sensitivity = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? sensitivity
        keyUpSounds = try c.decodeIfPresent(Bool.self, forKey: .keyUpSounds) ?? keyUpSounds
        stereoWidth = try c.decodeIfPresent(Float.self, forKey: .stereoWidth) ?? stereoWidth
        mutedBundleIDs = try c.decodeIfPresent([String].self, forKey: .mutedBundleIDs) ?? mutedBundleIDs
        muteWhileMicInUse = try c.decodeIfPresent(Bool.self, forKey: .muteWhileMicInUse) ?? muteWhileMicInUse
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? hotkey
        // v1 saved its continuous hit-strength settings; switch them to the slam accent once.
        if try c.decodeIfPresent(Int.self, forKey: .slamAccentVersion) == nil {
            hitStrengthEnabled = true
            sensitivity = 0.5
        }
    }
}

public final class SettingsStore {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public var settings: DownstrokeSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(DownstrokeSettings.self, from: $0) } ?? DownstrokeSettings()
    }

    public func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
