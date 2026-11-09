import Foundation

/// ADTS (Audio Data Transport Stream) header builder.
///
/// A raw AAC access unit carries no framing of its own, so a player cannot
/// tell where one frame ends and the next begins. ADTS wraps every access
/// unit with a 7-byte header that repeats the MPEG-4 audio configuration
/// (profile, sample rate, channel count) and states the frame length.
///
/// Layout of the 7-byte header (bits are numbered from the most significant):
///
///     byte 0: syncword                       11111111 1
///     byte 1: syncword(3) ID(1) layer(2) protection_absent(1)
///     byte 2: profile(2) sampling_frequency_index(4) private(1) channel_config(high bit)
///     byte 3: channel_config(low 2 bits) original home copyright_id copyright_id_start frame_length(high 2 bits)
///     byte 4: frame_length(middle 8 bits)
///     byte 5: frame_length(low 3 bits) buffer_fullness(high 5 bits)
///     byte 6: buffer_fullness(low 6 bits) number_of_raw_data_blocks
enum ADTSHeader {
    /// MPEG-4 sampling frequency index table (ISO/IEC 14496-3 table 1.18).
    static let samplingFrequencies: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
        22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Index into ``samplingFrequencies`` for the given rate, or nil if the
    /// rate has no ADTS representation.
    static func samplingFrequencyIndex(forSampleRate sampleRate: Int) -> Int? {
        samplingFrequencies.firstIndex(of: sampleRate)
    }

    /// Number of channels as an ADTS channel configuration (0 = undefined,
    /// 1..7 = mono up to 7.1, 8+ are reserved).
    static func channelConfiguration(forChannels channels: Int) -> Int {
        switch channels {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 6
        case 7: return 7
        case 8: return 7
        default: return 0
        }
    }

    /// Builds the 7-byte ADTS header for an access unit of `payloadLength` bytes.
    ///
    /// - Parameters:
    ///   - payloadLength: size of the raw AAC access unit in bytes.
    ///   - sampleRate: sample rate the access unit was encoded at.
    ///   - channels: channel count the access unit was encoded with.
    ///   - profile: MPEG-4 audio object type. Defaults to AAC LC (2), which is
    ///     what the built-in encoder produces.
    /// - Returns: the header bytes, or nil when the parameters cannot be
    ///   represented in ADTS (unknown sample rate, unsupported channel count,
    ///   or a frame too large for the 13-bit length field).
    static func make(payloadLength: Int,
                     sampleRate: Int,
                     channels: Int,
                     profile: UInt8 = 2) -> Data? {
        guard payloadLength > 0 else { return nil }
        guard let frequencyIndex = samplingFrequencyIndex(forSampleRate: sampleRate) else { return nil }
        let channelConfig = channelConfiguration(forChannels: channels)
        guard channelConfig > 0 else { return nil }
        guard profile >= 1, profile <= 4 else { return nil }

        let frameLength = payloadLength + 7
        guard frameLength < (1 << 13) else { return nil }

        // ADTS stores the audio object type in 2 bits as (type - 1).
        let profileBits = (profile - 1) & 0x03

        var bytes = [UInt8](repeating: 0, count: 7)
        bytes[0] = 0xFF
        // syncword low bits 1111, MPEG-4 (ID=0), layer 00, protection absent (no CRC)
        bytes[1] = 0xF1
        bytes[2] = (profileBits << 6) | (UInt8(frequencyIndex) << 2) | (UInt8(channelConfig >> 2) & 0x01)
        bytes[3] = (UInt8(channelConfig & 0x03) << 6) | (UInt8((frameLength >> 11) & 0x03))
        bytes[4] = UInt8((frameLength >> 3) & 0xFF)
        bytes[5] = (UInt8(frameLength & 0x07) << 5) | 0x1F
        // buffer fullness 0x7FF = variable bitrate, 0 raw data blocks in frame
        bytes[6] = 0xFC
        return Data(bytes)
    }
}
