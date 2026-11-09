import Testing
import AVFoundation
@testable import CastAudio

/// Regression test for the empty-stream defect: the interleaved PCM buffer
/// has to be allocated with its length, otherwise the converter hands an
/// empty payload to the encoder and the stream that reaches the speaker
/// carries no audio at all.
@Test func interleaveProducesNonEmptyPCM() throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    let frameCount: AVAudioFrameCount = 480
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    let channels = buffer.int16ChannelData!
    for frame in 0..<Int(frameCount) {
        channels[0][frame] = Int16(truncatingIfNeeded: frame)
        channels[1][frame] = Int16(truncatingIfNeeded: -frame)
    }

    let pcm = try #require(PCMConverter.interleave(buffer))

    #expect(pcm.count == Int(frameCount) * 2 * 2)
    #expect(pcm.count > 0)

    // Spot-check the interleaving order: left sample, then right sample.
    let samples = pcm.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self))
    }
    #expect(samples[0] == 0)
    #expect(samples[1] == 0)
    #expect(samples[2] == 1)
    #expect(samples[3] == -1)
}
