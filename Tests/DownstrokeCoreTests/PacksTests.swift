import DownstrokeCore
import Foundation
import Testing

private func vendoredPacks(file: String = #filePath) -> URL {
    var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
        dir.deleteLastPathComponent()
    }
    return dir.appendingPathComponent("Resources/SoundPacks")
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("downstroke-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePack(_ name: String, manifest: String, files: [String] = [], in root: URL) throws {
    let pack = root.appendingPathComponent("\(name).switchcraft")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    for file in files {
        let url = pack.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }
}

@Test func loadsVendoredPacks() throws {
    let boards = try PackLibrary.load(from: vendoredPacks())
    #expect(boards.count == 20)
    #expect(boards.first?.texture == .thocky)
    #expect(boards.first { $0.id == "holy-panda" }?.texture == .thocky)
    #expect(boards.allSatisfy { !$0.credits.isEmpty })
    let order = boards.map { Texture.allCases.firstIndex(of: $0.texture)! }
    #expect(order == order.sorted())
}

@Test func vendoredPackKeepsManifestFields() throws {
    let boards = try PackLibrary.load(from: vendoredPacks())
    let panda = try #require(boards.first { $0.id == "holy-panda" })
    #expect(panda.name == "Holy Panda")
    #expect(panda.color == "#F1E9DA")
    #expect(panda.manifest.deriveVelocityLayers == true)
    #expect(panda.manifest.gain == 1)
    #expect(panda.manifest.samples?["alpha"]?["hard"]?.count == 5)
    #expect(panda.folder.lastPathComponent == "holy-panda.switchcraft")
}

@Test func texturesHaveTitlesInDisplayOrder() {
    #expect(Texture.allCases.map(\.title) == ["Thocky", "Creamy", "Clacky", "Crisp", "Thump"])
}

@Test func rejectsWrongFormatVersion() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("bad-pack", manifest: #"{"formatVersion": 2, "name": "Bad"}"#, in: root)
    let (boards, errors) = try PackLibrary.loadReporting(from: root)
    #expect(boards.isEmpty)
    #expect(errors.count == 1)
    #expect(errors.first?.contains("bad-pack") == true)
}

@Test func skipsInvalidPacksAndKeepsGoodOnes() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("good", manifest: #"{"formatVersion": 1, "name": "Good", "credits": "c"}"#, files: ["sounds/alpha/hard/1.wav"], in: root)
    try writePack("broken", manifest: "not json", in: root)
    try writePack("no-name", manifest: #"{"formatVersion": 1, "name": ""}"#, in: root)
    try writePack("loud", manifest: #"{"formatVersion": 1, "name": "Loud", "gain": 5}"#, in: root)
    let (boards, errors) = try PackLibrary.loadReporting(from: root)
    #expect(boards.map(\.id) == ["good"])
    #expect(errors.count == 3)
}

@Test func missingTextureDefaultsToCrispAndIdToFolderName() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("plain", manifest: #"{"formatVersion": 1, "name": "Plain"}"#, files: ["sounds/alpha/hard/1.wav"], in: root)
    let board = try #require(try PackLibrary.load(from: root).first)
    #expect(board.id == "plain")
    #expect(board.texture == .crisp)
    #expect(board.credits == "")
}

@Test func sortsByTextureThenName() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = ["sounds/alpha/hard/1.wav"]
    try writePack("a", manifest: #"{"formatVersion": 1, "name": "Zeta", "texture": "thocky"}"#, files: wav, in: root)
    try writePack("b", manifest: #"{"formatVersion": 1, "name": "Alpha", "texture": "thocky"}"#, files: wav, in: root)
    try writePack("c", manifest: #"{"formatVersion": 1, "name": "Mid", "texture": "creamy"}"#, files: wav, in: root)
    try writePack("d", manifest: #"{"formatVersion": 1, "name": "Zip", "texture": "bogus"}"#, files: wav, in: root)
    let boards = try PackLibrary.load(from: root)
    #expect(boards.map(\.name) == ["Alpha", "Zeta", "Mid", "Zip"])
}

@Test func scansFoldersWhenSamplesMissing() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("scan", manifest: #"{"formatVersion": 1, "name": "Scan"}"#,
                  files: ["sounds/alpha/hard/1.wav", "sounds/alpha/hard/notes.txt"], in: root)
    let board = try #require(try PackLibrary.load(from: root).first)
    #expect(board.manifest.samples?["alpha"]?["hard"] == ["sounds/alpha/hard/1.wav"])
}

@Test func scanSortsPaths() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("scan", manifest: #"{"formatVersion": 1, "name": "Scan"}"#,
                  files: ["sounds/space/medium/2.wav", "sounds/space/medium/1.wav", "sounds/space/medium/10.wav"], in: root)
    let board = try #require(try PackLibrary.load(from: root).first)
    #expect(board.manifest.samples?["space"]?["medium"] == [
        "sounds/space/medium/1.wav", "sounds/space/medium/10.wav", "sounds/space/medium/2.wav",
    ])
}

@Test func packWithNoSamplesIsRejected() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePack("empty", manifest: #"{"formatVersion": 1, "name": "Empty"}"#, in: root)
    let (boards, errors) = try PackLibrary.loadReporting(from: root)
    #expect(boards.isEmpty)
    #expect(errors.count == 1)
}

@Test func unreadableDirectoryThrows() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(throws: (any Error).self) { try PackLibrary.load(from: missing) }
}
