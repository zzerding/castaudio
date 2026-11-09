import Foundation
import AVFoundation
import CoreMedia

/// Converts the audio buffers ScreenCaptureKit delivers into one canonical
/// format: interleaved little-endian PCM16, 48 kHz, stereo.
///
/// ScreenCaptureKit hands out buffers in whatever layout the system uses at
/// the time, so the conversion is done from the buffer's own format
/// description rather than assumed. That keeps the encoder fed with a
/// predictable stream no matter what the system hands over.
enum PCMConverter {
    /// The format the rest of the pipeline works in.
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    /// Converts one CMSampleBuffer into interleaved PCM16 bytes.
    ///
    /// - Returns: interleaved PCM16 bytes, or nil when the buffer cannot be
    ///   interpreted (no format description, or an unsupported layout).
    static func interleavedPCM16(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let sourceBuffer = makeSourceBuffer(from: sampleBuffer) else { return nil }
        guard let sourceFormat = sourceBuffer.format as AVAudioFormat? else { return nil }
        guard let converted = convert(sourceBuffer, from: sourceFormat) else { return nil }
        return interleave(converted)
    }

    /// Copies the sample buffer's audio into an AVAudioPCMBuffer that matches
    /// its own format description.
    private static func makeSourceBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return buffer
    }

    /// Resamples and remixes the source buffer into the target format.
    private static func convert(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if sourceFormat == targetFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var conversionError: NSError?
        var provided = false
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { return nil }
        return output
    }

    /// Turns the de-interleaved Int16 planes into interleaved bytes.
    private static func interleave(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channels = buffer.int16ChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        var output = Data(capacity: frameCount * channelCount * 2)
        output.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: Int16.self).baseAddress!
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    // A mono source reaching a stereo target is duplicated by
                    // the converter, but a stereo source with only one plane
                    // present is filled with silence for the missing channel.
                    let value: Int16
                    if channel < channelCount {
                        value = channels[channel][frame]
                    } else {
                        value = 0
                    }
                    base[frame * channelCount + channel] = value
                }
            }
        }
        return output
    }
}
