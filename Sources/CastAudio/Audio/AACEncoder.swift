import Foundation
import AudioToolbox

/// Encodes interleaved PCM16 audio into AAC access units wrapped in ADTS.
///
/// The Cast Default Media Receiver pulls an HTTP stream of ADTS-framed AAC,
/// so the encoder's job is: PCM in, `ADTS header + raw AAC access unit` out,
/// one call per access unit.
///
/// The platform encoder is driven through `AudioConverterFillComplexBuffer`
/// with `ioOutputDataPacketSize = 1`, which makes each call emit exactly one
/// access unit; the number of bytes written into the output buffer list is
/// that access unit's length, which is what the ADTS header has to declare.
final class AACEncoder {
    /// Encoder configuration. The values match what the capture layer
    /// produces, so no sample-rate conversion happens inside the converter.
    struct Configuration {
        var sampleRate: Double = 48_000
        var channels: UInt32 = 2
        var bitRate: UInt32 = 128_000
        /// AAC access units hold 1024 samples each.
        var framesPerAccessUnit: UInt32 = 1024
    }

    enum EncoderError: Error {
        case converterCreationFailed(OSStatus)
        case encodingFailed(OSStatus)
    }

    private var converter: AudioConverterRef?
    private let configuration: Configuration
    /// PCM bytes not yet consumed by the encoder, kept between calls so the
    /// converter can be fed in whatever chunk sizes capture delivers.
    private var pendingPCM = Data()
    /// Read position inside `pendingPCM`. The buffer is only trimmed once the
    /// encoder has consumed everything, so a caller's chunk boundaries never
    /// invalidate data the converter is still holding.
    private var pendingOffset = 0
    /// Staging buffer handed to the converter. It is raw allocated memory
    /// because the converter keeps reading from it after the input callback
    /// returns, so it cannot be a Swift value whose storage may move.
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    /// Maximum number of PCM frames the staging buffer can hold.
    private let inputCapacityFrames: Int

    init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        let bytesPerFrame = Int(configuration.channels) * 2
        self.inputCapacityFrames = 8_192
        self.inputBuffer = .allocate(capacity: inputCapacityFrames * bytesPerFrame)
        var converterRef: AudioConverterRef?
        var inputFormat = Self.inputFormat(for: configuration)
        var outputFormat = Self.outputFormat(for: configuration)
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converterRef)
        guard status == noErr, let converterRef else {
            inputBuffer.deallocate()
            throw EncoderError.converterCreationFailed(status)
        }
        converter = converterRef
        var bitRate = configuration.bitRate
        AudioConverterSetProperty(
            converterRef,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitRate
        )
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        inputBuffer.deallocate()
    }

    /// Encodes interleaved PCM16 samples and returns zero or more complete
    /// ADTS frames. The converter's internal delay means the first call
    /// usually returns nothing: those samples are held until the encoder
    /// emits its first access unit.
    ///
    /// - Parameter pcm: interleaved little-endian PCM16 frames.
    /// - Returns: ADTS-framed access units ready to be written to the stream.
    func encode(pcm: Data) throws -> [Data] {
        pendingPCM.append(pcm)
        var frames: [Data] = []
        while true {
            guard let accessUnit = try nextAccessUnit() else { break }
            guard let header = ADTSHeader.make(
                payloadLength: accessUnit.count,
                sampleRate: Int(configuration.sampleRate),
                channels: Int(configuration.channels)
            ) else { continue }
            var framed = header
            framed.append(accessUnit)
            frames.append(framed)
        }
        return frames
    }

    /// Feeds the converter until it produces one access unit.
    ///
    /// Returns nil when the converter needs more input before it can emit
    /// anything.
    private func nextAccessUnit() throws -> Data? {
        guard let converter else { return nil }

        let bytesPerFrame = Int(configuration.channels) * 2
        // The platform encoder asks for a whole access unit worth of input at
        // a time (measured: exactly 1024 frames per request). Feeding it a
        // partial request makes it stall without emitting anything, so we
        // only run it once a full unit is buffered.
        let availableFrames = (pendingPCM.count - pendingOffset) / bytesPerFrame
        guard availableFrames >= Int(configuration.framesPerAccessUnit) else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: Self.maxAccessUnitBytes)
        var packetCount: UInt32 = 1
        var bytesWritten = 0

        let status: OSStatus = output.withUnsafeMutableBytes { outputBytes in
            var outputList = AudioBufferList()
            outputList.mNumberBuffers = 1
            outputList.mBuffers.mData = outputBytes.baseAddress!
            outputList.mBuffers.mDataByteSize = UInt32(outputBytes.count)

            let fillStatus = AudioConverterFillComplexBuffer(
                converter,
                Self.inputProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &packetCount,
                &outputList,
                nil
            )
            bytesWritten = Int(outputList.mBuffers.mDataByteSize)
            return fillStatus
        }

        guard status == noErr else {
            throw EncoderError.encodingFailed(status)
        }
        guard packetCount == 1, bytesWritten > 0 else {
            return nil
        }
        // The very first access unit carries the encoder's priming samples.
        // It is kept in the stream on purpose: the decoder uses it to work
        // out its own delay, so dropping it would shift every later frame
        // against the audio timeline.
        return Data(output.prefix(bytesWritten))
    }

    /// The converter pulls PCM from here. `ioNumberDataPackets` is the
    /// capacity the converter asked for; we hand over as much as we have,
    /// copied into a staging buffer the converter can keep reading from
    /// after this callback returns.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, userData in
        guard let userData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let encoder = Unmanaged<AACEncoder>.fromOpaque(userData).takeUnretainedValue()
        return encoder.provideInput(ioNumberDataPackets, ioData)
    }

    private func provideInput(
        _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        _ ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let framesWanted = Int(ioNumberDataPackets.pointee)
        guard framesWanted > 0 else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let bytesPerFrame = Int(configuration.channels) * 2
        let availableFrames = (pendingPCM.count - pendingOffset) / bytesPerFrame
        let framesToGive = min(framesWanted, availableFrames, inputCapacityFrames)
        guard framesToGive > 0 else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let byteCount = framesToGive * bytesPerFrame
        pendingPCM.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(
                inputBuffer,
                base.advanced(by: pendingOffset),
                byteCount
            )
        }
        pendingOffset += byteCount
        if pendingOffset >= pendingPCM.count {
            pendingPCM.removeAll(keepingCapacity: true)
            pendingOffset = 0
        }
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(inputBuffer)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        ioNumberDataPackets.pointee = UInt32(framesToGive)
        return noErr
    }

    private static func inputFormat(for configuration: Configuration) -> AudioStreamBasicDescription {
        let bytesPerFrame = Int(configuration.channels) * 2
        return AudioStreamBasicDescription(
            mSampleRate: configuration.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: configuration.channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private static func outputFormat(for configuration: Configuration) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: configuration.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            // kMPEG4Object_AAC_LC
            mFormatFlags: 2,
            mBytesPerPacket: 0,
            mFramesPerPacket: configuration.framesPerAccessUnit,
            mBytesPerFrame: 0,
            mChannelsPerFrame: configuration.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// Upper bound for a single AAC access unit at the configured bit rate.
    private static let maxAccessUnitBytes = 64 * 1024
}
