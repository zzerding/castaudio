import Foundation
import Network
import Security

/// A live Cast V2 session with one device.
///
/// The channel is a TLS connection to port 8009 on the device. Cast devices
/// present a self-signed certificate, so the peer certificate is accepted
/// without validation; the channel is on the user's own LAN and carries
/// only local media control messages.
final class CastSession {
    enum SessionError: Error {
        case connectionFailed(String)
        case notConnected
    }

    /// The device this session talks to.
    let device: CastDevice

    /// Called when the session's state changes.
    var onStateChange: ((State) -> Void)?
    /// Called for every message the device sends.
    var onMessage: ((CastMessage) -> Void)?
    /// Called when the device reports its volume.
    var onVolumeChange: ((Double, Bool) -> Void)?
    /// Called when the device reports the media playback state, with the
    /// player's state ("PLAYING", "BUFFERING", "IDLE") and the position in
    /// seconds.
    var onPlaybackStateChange: ((String, Double) -> Void)?
    /// Called when the media namespace has been opened for a session and the
    /// device will accept a LOAD on it.
    var onMediaNamespaceReady: ((String) -> Void)?
    /// Called when the device has reported its platform status. A receiver
    /// has to be launched only after this point.
    var onPlatformReady: (() -> Void)?

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// The sender's own endpoint id on the channel.
    private let senderID = "sender-castaudio"
    /// The device-side endpoint id used before an app session exists.
    private let receiverID = "receiver-0"

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.castaudio.castsession")
    private var receiveBuffer = Data()
    private var requestCounter = 0
    private var heartbeatTimer: DispatchSourceTimer?
    /// Test hook that sees every payload before it goes on the wire.
    private var outgoingCapture: (([String: Any]) -> Void)?
    private var sessionID: String?
    private var transportID: String?
    /// Whether the media namespace has been opened for the current session.
    private var mediaNamespaceConnected = false
    /// Whether the device has reported its platform status yet.
    private var platformReady = false

    /// Whether the device reported a running application session, which is
    /// what the media load request needs to target.
    var hasMediaSession: Bool {
        sessionID != nil
    }

    init(device: CastDevice) {
        self.device = device
    }

    deinit {
        heartbeatTimer?.cancel()
        connection?.cancel()
    }

    // MARK: - Connection

    /// Opens the channel and completes the handshake.
    func connect() {
        guard connection == nil else { return }
        state = .connecting

        let parameters = Self.tlsParameters()
        let endpoint = device.endpoint
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.state = .connected
                self?.sendConnect()
                // The device only answers a LAUNCH after it has reported its
                // platform status once, so the status is requested right
                // after the handshake.
                self?.requestStatus()
                self?.startHeartbeat()
            case .failed(let error):
                self?.state = .failed(error.localizedDescription)
            case .cancelled:
                self?.state = .idle
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    /// Closes the channel.
    func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        sessionID = nil
        transportID = nil
        mediaNamespaceConnected = false
        platformReady = false
        state = .idle
    }

    /// TLS parameters that accept the device's self-signed certificate.
    private static func tlsParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in
                complete(true)
            },
            DispatchQueue.global(qos: .userInitiated)
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    // MARK: - Sending

    /// Sends a JSON payload on a namespace.
    func send(namespace: String, destinationID: String? = nil, payload: [String: Any]) {
        outgoingCapture?(payload)
        do {
            let message = try CastMessage.json(
                sourceID: senderID,
                destinationID: destinationID ?? receiverID,
                namespace: namespace,
                payload: payload
            )
            send(message)
        } catch {
            NSLog("[CastAudio] Cannot build Cast payload: \(error.localizedDescription)")
        }
    }

    /// Sends a raw message.
    func send(_ message: CastMessage) {
        guard let connection else { return }
        let frame = message.framed()
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                NSLog("[CastAudio] Send failed: \(error.localizedDescription)")
            }
        })
    }

    /// Opens the virtual connection to the device.
    private func sendConnect() {
        send(namespace: CastNamespace.connection, payload: Self.connectPayload)
    }

    /// The payload of a CONNECT message.
    ///
    /// The `senderInfo` block is part of the handshake the device expects;
    /// without it the device closes the channel right after the CONNECT.
    static let connectPayload: [String: Any] = [
        "type": "CONNECT",
        "userAgent": "CastAudio/1.0 (macOS)",
        "origin": [:] as [String: Any],
        "senderInfo": [
            "sdkType": 2,
            "version": "CastAudio/1.0",
            "browserVersion": "CastAudio/1.0",
            "platform": 6,
            "connectionType": 1
        ] as [String: Any]
    ]

    /// Opens a virtual connection on a namespace, addressed to one endpoint.
    ///
    /// The device treats every namespace as its own virtual connection. The
    /// media namespace in particular only accepts a LOAD after it has been
    /// CONNECTed with the application session id as the destination; without
    /// that step the device closes the channel instead of playing anything.
    ///
    /// `onOpen` is called once the request has been written, so the caller
    /// can follow up with a message on that namespace.
    func connectNamespace(namespace: String, destinationID: String, onOpen: (() -> Void)? = nil) {
        send(
            namespace: CastNamespace.connection,
            destinationID: destinationID,
            payload: Self.connectPayload
        )
        onOpen?()
    }

    /// Asks the device to launch the Default Media Receiver.
    func launchDefaultMediaReceiver() {
        requestCounter += 1
        send(namespace: CastNamespace.receiver, payload: [
            "type": "LAUNCH",
            "appId": CastDevice.defaultMediaReceiverID,
            "requestId": requestCounter
        ])
    }

    /// Tells the running receiver to play a media URL.
    ///
    /// The LOAD is addressed to the application session, and the media
    /// namespace has to be CONNECTed first — see `connectNamespace`.
    func loadMedia(url: URL, contentType: String = "audio/aac") {
        guard let sessionID else {
            NSLog("[CastAudio] Cannot load media before the receiver reports a session")
            return
        }
        requestCounter += 1
        let media: [String: Any] = [
            "contentId": url.absoluteString,
            "streamType": "LIVE",
            "contentType": contentType,
            "mediaSessionId": sessionID
        ]
        send(
            namespace: CastNamespace.media,
            destinationID: sessionID,
            payload: [
                "type": "LOAD",
                "media": media,
                "requestId": requestCounter
            ]
        )
    }

    /// Stops the media that is currently playing.
    func stopMedia() {
        guard let sessionID else { return }
        requestCounter += 1
        send(
            namespace: CastNamespace.media,
            destinationID: sessionID,
            payload: [
                "type": "STOP",
                "requestId": requestCounter,
                "mediaSessionId": sessionID
            ]
        )
    }

    /// Sets the receiver's volume.
    ///
    /// The `requestId` is not optional: without it the device accepts the
    /// message but never applies it. The device answers with a
    /// `RECEIVER_STATUS` and broadcasts a `DEVICE_UPDATED` carrying the new
    /// level.
    func setVolume(level: Double, muted: Bool? = nil) {
        requestCounter += 1
        var volume: [String: Any] = ["level": max(0, min(1, level))]
        if let muted {
            volume["muted"] = muted
        }
        send(namespace: CastNamespace.receiver, payload: [
            "type": "SET_VOLUME",
            "requestId": requestCounter,
            "volume": volume
        ])
    }

    /// Mutes or unmutes the receiver.
    func setMuted(_ muted: Bool) {
        requestCounter += 1
        send(namespace: CastNamespace.receiver, payload: [
            "type": "SET_VOLUME",
            "requestId": requestCounter,
            "volume": ["muted": muted]
        ])
    }

    /// Asks the receiver for its current status.
    func requestStatus() {
        requestCounter += 1
        send(namespace: CastNamespace.receiver, payload: [
            "type": "GET_STATUS",
            "requestId": requestCounter
        ])
    }

    // MARK: - Receiving

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.receiveBuffer.append(content)
                self.drainBuffer()
            }
            if let error {
                NSLog("[CastAudio] Receive failed: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
                return
            }
            if isComplete {
                self.state = .idle
                return
            }
            self.receiveNext()
        }
    }

    private func drainBuffer() {
        do {
            let messages = try CastMessage.decodeFramed(&receiveBuffer)
            for message in messages {
                handle(message)
            }
        } catch {
            NSLog("[CastAudio] Cannot decode Cast message: \(error.localizedDescription)")
            receiveBuffer.removeAll()
        }
    }

    /// Feeds a message into the session's message handling.
    ///
    /// Used by the tests to drive the state machine without a device.
    func handleForTesting(_ message: CastMessage) {
        handle(message)
    }

    /// Captures the payloads the session sends.
    ///
    /// Used by the tests to check what goes on the wire without a device.
    func captureOutgoingForTesting(_ handler: @escaping ([String: Any]) -> Void) {
        outgoingCapture = handler
    }

    private func handle(_ message: CastMessage) {
        onMessage?(message)

        guard let payload = try? message.jsonObject() else { return }
        let type = payload["type"] as? String ?? ""
        switch (message.namespace, type) {
        case (CastNamespace.heartbeat, "PING"):
            send(namespace: CastNamespace.heartbeat, payload: ["type": "PONG"])
        case (CastNamespace.connection, "CLOSE"):
            // The device closes the virtual connection while it replaces an
            // earlier session. The channel itself stays usable, so this is
            // logged rather than treated as a failure.
            NSLog("[CastAudio] Device closed the virtual connection")
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            readStatus(payload)
        case (CastNamespace.media, "MEDIA_STATUS"):
            readMediaStatus(payload)
        case (CastNamespace.receiver, "LAUNCH_ERROR"):
            let reason = payload["reason"] as? String ?? "unknown"
            state = .failed("启动接收器失败：\(reason)")
        case (CastNamespace.multizone, "DEVICE_UPDATED"):
            // The device broadcasts this when the volume changes from any
            // source, including another phone.
            readDeviceUpdate(payload)
        default:
            break
        }
    }

    /// Reads the volume out of a `DEVICE_UPDATED` broadcast.
    private func readDeviceUpdate(_ payload: [String: Any]) {
        guard let device = payload["device"] as? [String: Any],
              let volume = device["volume"] as? [String: Any] else { return }
        let level = volume["level"] as? Double ?? 0
        let muted = volume["muted"] as? Bool ?? false
        onVolumeChange?(level, muted)
    }

    private func readStatus(_ payload: [String: Any]) {
        guard let status = payload["status"] as? [String: Any] else { return }
        if let volume = status["volume"] as? [String: Any] {
            let level = volume["level"] as? Double ?? 0
            let muted = volume["muted"] as? Bool ?? false
            onVolumeChange?(level, muted)
        }
        // The first platform status means the device is ready for a LAUNCH.
        if !platformReady {
            platformReady = true
            onPlatformReady?()
        }
        if let applications = status["applications"] as? [[String: Any]] {
            for application in applications {
                guard let id = application["appId"] as? String,
                      id == CastDevice.defaultMediaReceiverID else { continue }
                guard let newSession = application["sessionId"] as? String else { continue }
                transportID = application["transportId"] as? String ?? newSession
                let connected = application["senderConnected"] as? Bool ?? false

                guard newSession != sessionID else {
                    // Same session, but the device may have just reported
                    // that this sender is now connected to the app.
                    if connected, !mediaNamespaceConnected {
                        openMediaNamespace(newSession)
                    }
                    continue
                }
                sessionID = newSession
                mediaNamespaceConnected = false
                openMediaNamespace(newSession)
            }
        }
    }

    /// Opens the media namespace for a session and reports when it is ready
    /// to accept a LOAD.
    private func openMediaNamespace(_ session: String) {
        connectNamespace(
            namespace: CastNamespace.media,
            destinationID: session
        ) { [weak self] in
            guard let self else { return }
            self.mediaNamespaceConnected = true
            self.onMediaNamespaceReady?(session)
        }
    }

    private func readMediaStatus(_ payload: [String: Any]) {
        guard let entries = payload["status"] as? [[String: Any]] else { return }
        guard let first = entries.first else { return }
        let playerState = first["playerState"] as? String ?? "UNKNOWN"
        let currentTime = first["currentTime"] as? Double ?? 0
        onPlaybackStateChange?(playerState, currentTime)
    }

    // MARK: - Heartbeat

    /// The device drops the channel when it stops hearing from us, so a PING
    /// goes out every few seconds.
    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(namespace: CastNamespace.heartbeat, payload: ["type": "PING"])
        }
        timer.resume()
        heartbeatTimer = timer
    }
}
