import Foundation
import AudioToolbox

/// Controls the local machine's output volume so the audio can be sent to
/// the speaker without also playing out of the Mac.
///
/// Android's reference implementation has three tiers, the strongest being
/// per-app muting through Shizuku. macOS has no public equivalent of
/// `VolumeShaper`'s exclusive-ID mechanism, so this offers the two tiers that
/// can be honoured honestly:
///
/// - `globalMute`: the system output volume is brought to zero while
///   streaming, and restored when streaming stops.
/// - `captureOnly`: the Mac keeps playing out loud.
///
/// Restoring the volume is deliberately conservative: if the user changed the
/// volume themselves during the session, their value wins and is left alone.
enum MuteMode: String, CaseIterable, Identifiable {
    case globalMute
    case captureOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalMute: return "本机静音"
        case .captureOnly: return "仅采集"
        }
    }
}

/// Reads and writes the system output volume through CoreAudio.
enum SystemVolume {
    /// The default output device, or nil when there is none.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceID == 0 ? nil : deviceID
    }

    /// Current output volume, 0...1.
    static func outputVolume() -> Float? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    /// Sets the output volume, 0...1. Returns false when the write failed.
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var volume = value
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr
    }
}

/// Drives the local mute state across a streaming session.
final class MuteController {
    /// The volume that was in place when muting started, restored on unmute
    /// unless the user changed it in the meantime.
    private(set) var savedVolume: Float?
    /// The volume this controller last wrote, used to tell "the user moved the
    /// slider" apart from "our own write is still in effect".
    private(set) var appliedVolume: Float?

    var mode: MuteMode = .globalMute {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// Whether the local output is currently muted by this controller.
    private(set) var isMuted = false

    /// The volume the user has set since we last wrote one, if any.
    private var userChangedVolume: Float? {
        guard let appliedVolume else { return nil }
        guard let current = SystemVolume.outputVolume() else { return nil }
        // A small tolerance: the system reports float values that can drift
        // by a hair when the user touches the volume control.
        guard abs(current - appliedVolume) > 0.001 else { return nil }
        return current
    }

    /// Starts muting according to the current mode.
    func applyMode() {
        switch mode {
        case .globalMute:
            mute()
        case .captureOnly:
            unmute()
        }
    }

    /// Brings the system output volume to zero, remembering the previous value.
    func mute() {
        guard !isMuted else { return }
        guard let current = SystemVolume.outputVolume() else { return }
        savedVolume = current
        if SystemVolume.setOutputVolume(0) {
            appliedVolume = 0
            isMuted = true
        }
    }

    /// Restores the previous volume.
    ///
    /// When the user moved the volume control while streaming, their choice
    /// wins: the volume is left where the user put it and the saved value is
    /// dropped.
    func unmute() {
        guard isMuted else { return }
        defer {
            isMuted = false
            savedVolume = nil
            appliedVolume = nil
        }
        if let userVolume = userChangedVolume {
            _ = userVolume
            return
        }
        if let saved = savedVolume {
            SystemVolume.setOutputVolume(saved)
        }
    }
}
