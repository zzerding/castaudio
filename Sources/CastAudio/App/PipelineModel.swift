import Foundation
import Combine
import CoreMedia

/// The four status dimensions the console shows, matching the Android
/// reference app.
enum PipelineStatus: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .starting: return "STARTING"
        case .running: return "LIVE"
        case .failed: return "ERROR"
        }
    }
}

/// Owns the whole pipeline: capture → encode → serve.
///
/// The pieces are deliberately separate so each can be tested on its own:
/// `SystemAudioCapture` produces PCM, `AACEncoder` turns it into ADTS frames,
/// `AudioStreamServer` hands those frames to whoever asks for the stream.
@MainActor
final class PipelineModel: ObservableObject {
    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var streamURL: URL?
    @Published private(set) var clientCount = 0
    /// Peak level of the last second of audio, in dBFS. -60 means silence.
    @Published private(set) var levelDBFS: Float = -60
    @Published private(set) var errorMessage: String?

    @Published var muteMode: MuteMode = .globalMute {
        didSet { muteController.mode = muteMode }
    }

    private let capture = SystemAudioCapture()
    private let muteController = MuteController()
    private var encoder: AACEncoder?
    private let server = AudioStreamServer()
    private var levelTracker = LevelTracker()

    /// Whether the app holds Screen Recording permission, checked once the
    /// capture is started.
    @Published private(set) var hasScreenRecordingPermission: Bool?

    init() {
        capture.onPCM = { [weak self] pcm in
            Task { @MainActor in
                self?.handlePCM(pcm)
            }
        }
        server.onClientCountChange = { [weak self] count in
            Task { @MainActor in
                self?.clientCount = count
            }
        }
    }

    /// Starts the pipeline.
    func start() async {
        guard status == .idle || isFailed else { return }
        errorMessage = nil
        status = .starting

        do {
            encoder = try AACEncoder()
        } catch {
            fail("编码器启动失败：\(error.localizedDescription)")
            return
        }

        do {
            try server.start()
        } catch {
            fail("本地推流服务启动失败：\(error.localizedDescription)")
            return
        }
        streamURL = server.streamURL()

        do {
            try await capture.start()
        } catch {
            server.stop()
            streamURL = nil
            let denied = !(await SystemAudioCapture.hasScreenRecordingPermission())
            if denied {
                fail("未获得屏幕录制权限。请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许投音 Mac。")
            } else {
                fail("采集启动失败：\(error.localizedDescription)")
            }
            return
        }

        hasScreenRecordingPermission = true
        muteController.mode = muteMode
        status = .running
    }

    /// Stops the pipeline and restores the local volume.
    func stop() async {
        await capture.stop()
        server.stop()
        encoder = nil
        streamURL = nil
        clientCount = 0
        levelTracker.reset()
        levelDBFS = -60
        muteController.unmute()
        status = .idle
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func handlePCM(_ pcm: Data) {
        guard let encoder else { return }
        levelTracker.consume(pcm)
        levelDBFS = levelTracker.levelDBFS
        do {
            let frames = try encoder.encode(pcm: pcm)
            for frame in frames {
                server.broadcast(frame)
            }
        } catch {
            fail("编码失败：\(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        status = .failed(message)
    }
}

/// Tracks the peak level of recent audio so the console can show whether
/// there is real sound in the stream.
final class LevelTracker {
    private var samples: [Int16] = []
    private let windowSize = 48_000

    func consume(_ pcm: Data) {
        guard pcm.count >= 2 else { return }
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            samples.append(contentsOf: values)
        }
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    func reset() {
        samples.removeAll()
    }

    /// Current peak level in dBFS, or -60 when there is no signal.
    var levelDBFS: Float {
        guard !samples.isEmpty else { return -60 }
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(Float(sample))
            if magnitude > peak {
                peak = magnitude
            }
        }
        guard peak > 0 else { return -60 }
        let db = 20 * log10(peak / 32_768)
        return max(-60, db)
    }
}
