import AVFoundation
import Foundation

/// Decoded audio: one or two channels of Float samples.
public struct PCMClip: Sendable {
    public var left: [Float]
    public var right: [Float]?

    public init(left: [Float], right: [Float]? = nil) {
        self.left = left
        self.right = right
    }

    public var frameCount: Int { left.count }
}

public enum AudioDecoder {
    public struct DecodeError: LocalizedError {
        public var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Reads `url` as Float32 at `sampleRate`, keeping the first one or two channels.
    public static func decode(_ url: URL, sampleRate: Double) throws -> PCMClip {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        let channels = min(2, Int(source.channelCount))
        guard length > 0, channels > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: length) else {
            throw DecodeError("\(url.lastPathComponent) is empty")
        }
        try file.read(into: input)
        guard let data = input.floatChannelData else { throw DecodeError("\(url.lastPathComponent) has no sample data") }
        let frames = Int(input.frameLength)
        let sameRate = abs(source.sampleRate - sampleRate) < 0.5
        if sameRate {
            return clip(channels: (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
        }

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                           channels: AVAudioChannelCount(channels), interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let trimmed = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)),
              let trimmedData = trimmed.floatChannelData else {
            throw DecodeError("can't convert \(url.lastPathComponent) to \(Int(sampleRate)) Hz")
        }
        for c in 0..<channels { trimmedData[c].update(from: data[c], count: frames) }
        trimmed.frameLength = AVAudioFrameCount(frames)

        let capacity = AVAudioFrameCount((Double(frames) * sampleRate / source.sampleRate).rounded(.up)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity),
              let outData = output.floatChannelData else {
            throw DecodeError("can't allocate a buffer for \(url.lastPathComponent)")
        }
        nonisolated(unsafe) var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return trimmed
        }
        if status == .error { throw convertError ?? DecodeError("conversion of \(url.lastPathComponent) failed") }
        let outFrames = Int(output.frameLength)
        return clip(channels: (0..<channels).map { Array(UnsafeBufferPointer(start: outData[$0], count: outFrames)) })
    }

    private static func clip(channels: [[Float]]) -> PCMClip {
        PCMClip(left: channels[0], right: channels.count > 1 ? channels[1] : nil)
    }
}
