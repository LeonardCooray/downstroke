import Foundation

/// How a switch sounds, used to group boards in the picker.
public enum Texture: String, CaseIterable, Codable, Sendable {
    case thocky, creamy, clacky, crisp, thump

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// manifest.json of a Switchcraft format v1 pack, plus Downstroke's `texture` and `color`.
public struct PackManifest: Codable, Sendable {
    public var formatVersion: Int
    public var id: String?
    public var name: String
    public var author: String?
    public var description: String?
    public var category: String?
    public var credits: String?
    public var gain: Double?
    public var deriveVelocityLayers: Bool?
    /// Group, then layer, then paths relative to the pack folder.
    public var samples: [String: [String: [String]]]?
    public var texture: Texture?
    public var color: String?

    public init(
        formatVersion: Int = 1, id: String? = nil, name: String, author: String? = nil, description: String? = nil,
        category: String? = nil, credits: String? = nil, gain: Double? = nil, deriveVelocityLayers: Bool? = nil,
        samples: [String: [String: [String]]]? = nil, texture: Texture? = nil, color: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.author = author
        self.description = description
        self.category = category
        self.credits = credits
        self.gain = gain
        self.deriveVelocityLayers = deriveVelocityLayers
        self.samples = samples
        self.texture = texture
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        credits = try c.decodeIfPresent(String.self, forKey: .credits)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain)
        deriveVelocityLayers = try c.decodeIfPresent(Bool.self, forKey: .deriveVelocityLayers)
        samples = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .samples)
        // An unknown texture falls back to the default instead of rejecting the pack.
        texture = try? c.decodeIfPresent(Texture.self, forKey: .texture)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

/// A loaded sound pack as the app presents it.
public struct Board: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let texture: Texture
    public let color: String
    public let credits: String
    public let folder: URL
    public let manifest: PackManifest
}

public enum PackLibrary {
    static let defaultColor = "#8E8E93"
    static let layers = ["soft", "medium", "hard", "slam", "release"]
    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf"]

    /// Loads every valid pack in `directory`; throws only when the directory can't be read.
    public static func load(from directory: URL) throws -> [Board] {
        try loadReporting(from: directory).0
    }

    /// Like `load`, and also returns one message per skipped pack.
    public static func loadReporting(from directory: URL) throws -> ([Board], [String]) {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        var boards: [Board] = []
        var errors: [String] = []
        for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where folder.pathExtension == "switchcraft" {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do {
                boards.append(try board(at: folder))
            } catch {
                errors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        boards.sort(by: ordered)
        return (boards, errors)
    }

    private struct PackError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func board(at folder: URL) throws -> Board {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("manifest.json")) } catch {
            throw PackError("manifest.json is missing or unreadable")
        }
        var manifest: PackManifest
        do { manifest = try JSONDecoder().decode(PackManifest.self, from: data) } catch {
            throw PackError("manifest.json is not valid")
        }
        guard manifest.formatVersion == 1 else { throw PackError("unsupported formatVersion \(manifest.formatVersion)") }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PackError("name is empty") }
        if let gain = manifest.gain, !(0...4).contains(gain) { throw PackError("gain \(gain) is outside 0 to 4") }
        if manifest.samples == nil { manifest.samples = scanSamples(in: folder) }
        guard hasUsableSample(manifest, in: folder) else { throw PackError("no usable samples") }
        return Board(
            id: manifest.id ?? String(folder.lastPathComponent.dropLast(".switchcraft".count)),
            name: manifest.name,
            texture: manifest.texture ?? .crisp,
            color: manifest.color ?? defaultColor,
            credits: manifest.credits ?? "",
            folder: folder,
            manifest: manifest
        )
    }

    private static func ordered(_ a: Board, _ b: Board) -> Bool {
        let ta = Texture.allCases.firstIndex(of: a.texture)!, tb = Texture.allCases.firstIndex(of: b.texture)!
        if ta != tb { return ta < tb }
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    private static func hasUsableSample(_ manifest: PackManifest, in folder: URL) -> Bool {
        let fm = FileManager.default
        return (manifest.samples ?? [:]).values.flatMap { $0.values.joined() }.contains {
            fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Fills group, layer, paths from `sounds/<group>/<layer>/*`.
    private static func scanSamples(in folder: URL) -> [String: [String: [String]]] {
        let fm = FileManager.default
        var samples: [String: [String: [String]]] = [:]
        for group in KeyGroup.allCases.map(\.rawValue) {
            for layer in layers {
                let relative = "sounds/\(group)/\(layer)"
                let dir = folder.appendingPathComponent(relative)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                let paths = names
                    .filter { !$0.hasPrefix(".") && audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                    .sorted()
                    .map { "\(relative)/\($0)" }
                if !paths.isEmpty { samples[group, default: [:]][layer] = paths }
            }
        }
        return samples
    }
}
