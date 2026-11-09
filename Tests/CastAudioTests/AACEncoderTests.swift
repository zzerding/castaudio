import Foundation
import Testing
@testable import CastAudio

/// Builds a stereo PCM16 buffer holding a sine tone.
private func sinePCM(frames: Int, frequency: Double = 440, sampleRate: Double = 48_000) -> Data {
    var samples = [Int16](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let value = Int16(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 12_000)
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    return samples.withUnsafeBytes { Data($0) }
}

/// Parses ADTS frames out of a stream, returning their payload sizes.
private func parseADTSFrames(_ data: Data) -> [Int] {
    var sizes: [Int] = []
    var offset = 0
    let bytes = [UInt8](data)
    while offset + 7 <= bytes.count {
        guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { break }
        let frameLength = (Int(bytes[offset + 3] & 0x03) << 11)
            | (Int(bytes[offset + 4]) << 3)
            | (Int(bytes[offset + 5]) >> 5)
        guard frameLength >= 7, offset + frameLength <= bytes.count else { break }
        sizes.append(frameLength - 7)
        offset += frameLength
    }
    return sizes
}

@Test func encoderProducesADTSFramesForAudio() throws {
    let encoder = try AACEncoder()
    let pcm = sinePCM(frames: 48_000)

    var frames: [Data] = []
    // Feed in chunks, the way the capture layer delivers audio.
    let chunkSize = 4096
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkSize, pcm.count)
        frames.append(contentsOf: try encoder.encode(pcm: pcm.subdata(in: offset..<end)))
        offset = end
    }

    #expect(!frames.isEmpty)

    let stream = frames.reduce(into: Data()) { $0.append($1) }
    let payloads = parseADTSFrames(stream)
    #expect(!payloads.isEmpty)
    // Every parsed frame must cover the whole stream: no leftover bytes and
    // no misalignment.
    let consumed = payloads.reduce(0) { $0 + $1 + 7 }
    #expect(consumed == stream.count)
    // AAC payloads carry real audio, not empty placeholders.
    for size in payloads {
        #expect(size > 0)
    }
}

@Test func encoderIsDeterministicForSameInput() throws {
    let pcm = sinePCM(frames: 16_000)

    func run() throws -> [Data] {
        let encoder = try AACEncoder()
        return try encoder.encode(pcm: pcm)
    }

    let first = try run()
    let second = try run()
    #expect(first == second)
}

@Test func encoderWithSilenceStillProducesFrames() throws {
    let encoder = try AACEncoder()
    let silence = Data(repeating: 0, count: 48_000 * 4)
    let frames = try encoder.encode(pcm: silence)
    #expect(!frames.isEmpty)
}

@Test func levelTrackerReportsSilenceAsFloor() {
    let tracker = LevelTracker()
    #expect(abs(tracker.levelDBFS - (-60)) < 0.001)

    tracker.consume(Data(repeating: 0, count: 4096))
    #expect(abs(tracker.levelDBFS - (-60)) < 0.001)
}

@Test func levelTrackerReportsSignalAboveFloor() {
    let tracker = LevelTracker()
    tracker.consume(sinePCM(frames: 4_800))
    #expect(tracker.levelDBFS > -40)
    #expect(tracker.levelDBFS < 0)
}
