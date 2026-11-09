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

/// State of the link to the selected speaker.
enum CastLinkState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        }
    }
}

/// Owns the whole pipeline: capture → encode → serve → cast.
///
/// The pieces are deliberately separate so each can be tested on its own:
/// `SystemAudioCapture` produces PCM, `AACEncoder` turns it into ADTS frames,
/// `AudioStreamServer` hands those frames to whoever asks for the stream, and
/// `CastSession` tells the speaker to play that stream.
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

    // MARK: - Cast

    /// Speakers found on the local network.
    @Published private(set) var devices: [CastDevice] = []
    /// The speaker the user picked.
    @Published var selectedDeviceID: String? {
        didSet { selectedDeviceChanged() }
    }
    /// State of the link to the selected speaker.
    @Published private(set) var castLinkState: CastLinkState = .idle
    /// The speaker's volume, 0...1.
    @Published private(set) var speakerVolume: Double = 1
    /// Whether the speaker is muted.
    @Published private(set) var speakerMuted = false
    /// Whether the app is looking for speakers.
    @Published private(set) var isDiscovering = false

    private let discovery = CastDiscovery()
    private var session: CastSession?

    /// The speaker currently selected, if any.
    var selectedDevice: CastDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

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
        discovery.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.devices = devices
                // Keep a selection if the device is still there; otherwise
                // fall back to the first one found.
                if let current = self?.selectedDeviceID,
                   devices.contains(where: { $0.id == current }) {
                    return
                }
                self?.selectedDeviceID = devices.first?.id
            }
        }
    }

    // MARK: - Discovery

    /// Starts or stops looking for speakers.
    func toggleDiscovery() {
        if isDiscovering {
            discovery.stop()
            isDiscovering = false
        } else {
            discovery.start()
            isDiscovering = true
        }
    }

    private func selectedDeviceChanged() {
        // A different speaker means a different session; drop the old one.
        session?.disconnect()
        session = nil
        castLinkState = .idle
        speakerVolume = 1
        speakerMuted = false
    }

    // MARK: - Pipeline

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

        // Tell the speaker to play the stream we are serving.
        connectToSelectedDevice()
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
        session?.disconnect()
        session = nil
        castLinkState = .idle
        status = .idle
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - Cast control

    /// Opens the channel to the selected speaker and asks it to play the
    /// stream.
    func connectToSelectedDevice() {
        guard let device = selectedDevice, let url = streamURL else { return }
        session?.disconnect()

        let session = CastSession(device: device)
        self.session = session

        session.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .connected:
                    self.castLinkState = .connected
                    // Launch the Default Media Receiver, then load the
                    // stream once the receiver reports its session.
                    session.launchDefaultMediaReceiver()
                case .connecting:
                    self.castLinkState = .connecting
                case .failed(let message):
                    self.castLinkState = .failed(message)
                case .idle:
                    self.castLinkState = .idle
                }
            }
        }
        session.onVolumeChange = { [weak self] level, muted in
            Task { @MainActor in
                self?.speakerVolume = level
                self?.speakerMuted = muted
            }
        }
        session.onMessage = { [weak self] message in
            // Once the receiver reports its session id, the media can be
            // loaded on the transport.
            guard let self else { return }
            guard message.namespace == CastNamespace.receiver else { return }
            guard let payload = try? message.jsonObject(),
                  let type = payload["type"] as? String,
                  type == "RECEIVER_STATUS" else { return }
            Task { @MainActor in
                if self.session?.hasMediaSession == true, let url = self.streamURL {
                    self.session?.loadMedia(url: url)
                }
            }
        }

        castLinkState = .connecting
        session.connect()
    }

    /// Sets the speaker's volume.
    func setSpeakerVolume(_ level: Double) {
        speakerVolume = level
        session?.setVolume(level: level)
    }

    /// Mutes or unmutes the speaker.
    func toggleSpeakerMute() {
        speakerMuted.toggle()
        session?.setMuted(speakerMuted)
    }

    // MARK: - Internals

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
