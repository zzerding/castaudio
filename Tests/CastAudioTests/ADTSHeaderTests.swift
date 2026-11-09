import Foundation
import Testing
@testable import CastAudio

@Test func adtsHeaderHasCorrectSyncwordAndMPEG4Layout() throws {
    let header = try #require(ADTSHeader.make(payloadLength: 100, sampleRate: 48_000, channels: 2))
    let bytes = [UInt8](header)

    #expect(bytes.count == 7)
    // Syncword is 12 bits of 1.
    #expect(bytes[0] == 0xFF)
    // MPEG-4 (ID = 0), layer 00, no CRC.
    #expect(bytes[1] == 0xF1)
}

@Test func adtsHeaderDeclaresFrameLength() throws {
    let payloadLength = 173
    let header = try #require(ADTSHeader.make(payloadLength: payloadLength, sampleRate: 48_000, channels: 2))
    let bytes = [UInt8](header)

    // The 13-bit frame length spans the last bits of byte 3, byte 4 and the
    // top bits of byte 5. It counts the header itself plus the payload.
    let frameLength = (Int(bytes[3] & 0x03) << 11)
        | (Int(bytes[4]) << 3)
        | (Int(bytes[5]) >> 5)
    #expect(frameLength == payloadLength + 7)
}

@Test func adtsHeaderEncodesProfileRateAndChannels() throws {
    let header = try #require(ADTSHeader.make(payloadLength: 50, sampleRate: 48_000, channels: 2))
    let bytes = [UInt8](header)

    // Profile 1 = AAC LC (the object type minus one).
    let profile = (bytes[2] & 0xC0) >> 6
    #expect(profile == 1)
    // Sampling frequency index 3 = 48 kHz.
    let frequencyIndex = (bytes[2] & 0x3C) >> 2
    #expect(frequencyIndex == 3)
    // Channel configuration 2 = stereo.
    let channelConfig = ((bytes[2] & 0x01) << 2) | ((bytes[3] & 0xC0) >> 6)
    #expect(channelConfig == 2)
}

@Test func adtsHeaderRejectsUnsupportedParameters() {
    #expect(ADTSHeader.make(payloadLength: 100, sampleRate: 44_100 + 1, channels: 2) == nil)
    #expect(ADTSHeader.make(payloadLength: 0, sampleRate: 48_000, channels: 2) == nil)
    #expect(ADTSHeader.make(payloadLength: 100, sampleRate: 48_000, channels: 0) == nil)
}

@Test func adtsSamplingFrequencyTableMatchesKnownRates() {
    #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 48_000) == 3)
    #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 44_100) == 4)
    #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 16_000) == 8)
    #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 12_345) == nil)
}
