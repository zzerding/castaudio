import Testing
import AVFoundation
@testable import CastAudio

/// Regression tests for the empty-stream defect.
///
/// The interleaved PCM buffer used to be allocated with its capacity only,
/// so its length stayed at zero and the bytes written into it landed outside
/// the buffer. The encoder then received an empty payload for every
/// captured frame and the stream carried no audio at all, while the stream
/// itself connected and the speaker reported PLAYING.

/// A buffer already in the target format must come out as interleaved
/// bytes with the left and right samples in the expected order.
@Test func interleavedPCM16FromTargetFormatBufferIsNotEmpty() throws {
    let frames = 480
    let format = try #require(PCMConverter.targetFormat)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)

    let channels = try #require(buffer.int16ChannelData)
    for frame in 0..<frames {
        channels[0][frame] = Int16(truncatingIfNeeded: frame)
        channels[1][frame] = Int16(truncatingIfNeeded: -frame)
    }

    let pcm = try #require(PCMConverter.interleavedPCM16(from: buffer))
    #expect(pcm.count == frames * 2 * 2)

    let interleaved = pcm.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self))
    }
    #expect(interleaved[0] == 0)
    #expect(interleaved[1] == 0)
    #expect(interleaved[2] == 1)
    #expect(interleaved[3] == -1)
}

/// A mono buffer in another sample rate has to be resampled and remixed
/// into the target format, and the result must carry audio.
@Test func interleavedPCM16ResamplesMonoToTargetFormat() throws {
    let frames = 441
    let sourceFormat = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)

    let channels = try #require(buffer.int16ChannelData)
    for frame in 0..<frames {
        channels[0][frame] = Int16(truncatingIfNeeded: frame)
    }

    let pcm = try #require(PCMConverter.interleavedPCM16(from: buffer))
    #expect(pcm.count > 0)
    #expect(pcm.count % 4 == 0)
}
