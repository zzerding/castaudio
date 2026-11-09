import Foundation
import ScreenCaptureKit
import CoreMedia
import Combine

/// Captures the audio the system is playing via ScreenCaptureKit.
///
/// macOS has no public API to read back one application's playback audio the
/// way Android's `AudioPlaybackCapture` does per UID. ScreenCaptureKit is the
/// supported equivalent: it captures the audio of the applications that are
/// part of the content filter.
///
/// Two constraints come with it:
/// - The user must grant Screen Recording permission. Without it the system
///   refuses to hand out any content at all.
/// - The capture cannot include this app's own output, otherwise the app
///   would feed its own playback back into the stream. That is handled by
///   `excludesCurrentProcessAudio`.
final class SystemAudioCapture {
    enum CaptureError: Error {
        case noContentAvailable
        case noDisplay
        case streamSetupFailed(String)
    }

    /// Emits interleaved PCM16 bytes, 48 kHz, stereo.
    var onPCM: ((Data) -> Void)?
    /// Reports a fatal capture failure.
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.castaudio.capture")

    /// Whether the process currently holds Screen Recording permission.
    ///
    /// Checked by asking for the shareable content; the system raises the
    /// permission prompt or denies the request.
    static func hasScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// Starts capturing system audio.
    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Including every running application is what makes this the
        // macOS counterpart of the Android app whitelist: the filter decides
        // whose audio is captured.
        let filter = SCContentFilter(
            display: display,
            including: content.applications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = false

        let output = AudioStreamOutput(onPCM: { [weak self] data in
            self?.onPCM?(data)
        })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }
        self.stream = stream
    }

    /// Stops capturing.
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
}

/// Receives audio buffers from ScreenCaptureKit and converts them.
private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onPCM: (Data) -> Void
    private var failureHandler: ((Error) -> Void)?

    init(onPCM: @escaping (Data) -> Void) {
        self.onPCM = onPCM
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcm = PCMConverter.interleavedPCM16(from: sampleBuffer) else { return }
        onPCM(pcm)
    }

    func stream(_ stream: SCStream, didFailWithError error: Error) {
        failureHandler?(error)
    }
}
