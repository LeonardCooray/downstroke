import Foundation
import Synchronization

/// A clip inside a bank's storage; valid for as long as the bank lives.
public struct ClipRef: @unchecked Sendable {
    public let left: UnsafePointer<Float>
    public let right: UnsafePointer<Float>?
    public let frames: Int
}

private let nextBankTag = Atomic<Int>(0)

/// Every clip of one board at one sample rate, immutable after init so the render thread can read it without locks.
public final class SampleBank: @unchecked Sendable {
    public struct LoadError: LocalizedError {
        public var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public let boardID: String
    /// Unique per bank, so voices can say which bank they read from.
    public let tag: Int

    // One allocation for the whole bank: a single free, and clips sit next to each other.
    private let storage: UnsafeMutablePointer<Float>
    private let floatCount: Int
    // Press clips by group index * 4 + layer, release clips by group index, fallbacks already resolved.
    private let pressTable: [[ClipRef]]
    private let releaseTable: [[ClipRef]]

    public var byteCount: Int { floatCount * MemoryLayout<Float>.stride }

    public init(board: Board, sampleRate: Double) throws {
        let groups = KeyGroup.allCases
        let samples = board.manifest.samples ?? [:]
        let gain = Float(board.manifest.gain ?? 1)
        let derive = board.manifest.deriveVelocityLayers ?? false
        let root = board.folder.standardizedFileURL.resolvingSymlinksInPath().path

        var presses: [[Layer: [PCMClip]]] = Array(repeating: [:], count: groups.count)
        var releases: [[PCMClip]] = Array(repeating: [], count: groups.count)
        for (index, group) in groups.enumerated() {
            guard let layers = samples[group.rawValue] else { continue }
            for (name, paths) in layers {
                let clips = paths.compactMap { Self.decode($0, in: board.folder, root: root, sampleRate: sampleRate) }
                if name == "release" {
                    releases[index] = clips
                } else if let layer = Self.layer(named: name), !clips.isEmpty {
                    presses[index][layer] = clips
                }
            }
            if derive, let hard = presses[index][.hard] {
                var derived: [Layer: [PCMClip]] = [:]
                for clip in hard {
                    for (layer, result) in LayerDerivation.derive(from: clip, sampleRate: sampleRate) {
                        derived[layer, default: []].append(result)
                    }
                }
                // Recorded layers win over derived ones.
                presses[index].merge(derived) { recorded, _ in recorded }
            }
        }
        guard presses.contains(where: { !$0.isEmpty }) else {
            throw LoadError("\(board.name) has no usable press samples")
        }

        var allClips: [PCMClip] = []
        func append(_ clips: [PCMClip]) -> Range<Int> {
            let start = allClips.count
            allClips.append(contentsOf: clips)
            return start..<allClips.count
        }
        var pressRanges: [[Range<Int>]] = []
        var releaseRanges: [Range<Int>] = []
        for index in groups.indices {
            pressRanges.append(Layer.allCases.map { append(presses[index][$0] ?? []) })
            releaseRanges.append(append(releases[index]))
        }

        let total = allClips.reduce(0) { $0 + $1.frameCount * ($1.right == nil ? 1 : 2) }
        let base = UnsafeMutablePointer<Float>.allocate(capacity: max(total, 1))
        var refs: [ClipRef] = []
        var cursor = 0
        for clip in allClips {
            let frames = clip.frameCount
            let left = base + cursor
            for i in 0..<frames { left[i] = clip.left[i] * gain }
            cursor += frames
            var right: UnsafeMutablePointer<Float>?
            if let r = clip.right {
                right = base + cursor
                for i in 0..<frames { right![i] = r[i] * gain }
                cursor += frames
            }
            refs.append(ClipRef(left: UnsafePointer(left), right: right.map { UnsafePointer($0) }, frames: frames))
        }

        let alpha = groups.firstIndex(of: .alpha)!
        let pressRefs = pressRanges.map { $0.map { Array(refs[$0]) } }
        let releaseRefs = releaseRanges.map { Array(refs[$0]) }
        var pressTable: [[ClipRef]] = []
        for index in groups.indices {
            let source = pressRefs[index].allSatisfy(\.isEmpty) ? alpha : index
            for layer in Layer.allCases {
                pressTable.append(Self.nearest(layer, in: pressRefs[source]))
            }
        }

        self.boardID = board.id
        self.tag = nextBankTag.add(1, ordering: .relaxed).newValue
        self.storage = base
        self.floatCount = total
        self.pressTable = pressTable
        self.releaseTable = groups.indices.map { releaseRefs[$0].isEmpty ? releaseRefs[alpha] : releaseRefs[$0] }
    }

    deinit { storage.deallocate() }

    public func presses(_ group: KeyGroup, _ layer: Layer) -> [ClipRef] {
        pressTable[Self.index(of: group) * Layer.allCases.count + layer.rawValue]
    }

    public func releases(_ group: KeyGroup) -> [ClipRef] {
        releaseTable[Self.index(of: group)]
    }

    private static func index(of group: KeyGroup) -> Int {
        KeyGroup.allCases.firstIndex(of: group)!
    }

    private static func layer(named name: String) -> Layer? {
        switch name {
        case "soft": .soft
        case "medium": .medium
        case "hard": .hard
        case "slam": .slam
        default: nil
        }
    }

    /// The layer's own clips, else the closest layer by index; a tie goes to the louder one.
    private static func nearest(_ layer: Layer, in clips: [[ClipRef]]) -> [ClipRef] {
        let present = Layer.allCases.filter { !clips[$0.rawValue].isEmpty }
        guard let best = present.min(by: { a, b in
            let da = abs(a.rawValue - layer.rawValue), db = abs(b.rawValue - layer.rawValue)
            return da != db ? da < db : a.rawValue > b.rawValue
        }) else { return [] }
        return clips[best.rawValue]
    }

    private static func decode(_ path: String, in folder: URL, root: String, sampleRate: Double) -> PCMClip? {
        let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root + "/") else { return nil }
        return try? AudioDecoder.decode(url, sampleRate: sampleRate)
    }
}
