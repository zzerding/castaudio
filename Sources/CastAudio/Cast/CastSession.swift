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
    private var sessionID: String?
    private var transportID: String?

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
        send(namespace: CastNamespace.connection, payload: [
            "type": "CONNECT",
            "userAgent": "CastAudio/1.0 (macOS)",
            "origin": [:] as [String: Any]
        ])
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
    func loadMedia(url: URL, contentType: String = "audio/aac") {
        requestCounter += 1
        var media: [String: Any] = [
            "contentId": url.absoluteString,
            "streamType": "LIVE",
            "contentType": contentType
        ]
        if let transportID {
            media["mediaSessionId"] = transportID
        }
        send(namespace: CastNamespace.media, payload: [
            "type": "LOAD",
            "media": media,
            "requestId": requestCounter
        ])
    }

    /// Sets the receiver's volume.
    func setVolume(level: Double, muted: Bool? = nil) {
        var volume: [String: Any] = ["level": max(0, min(1, level))]
        if let muted {
            volume["muted"] = muted
        }
        send(namespace: CastNamespace.receiver, payload: [
            "type": "SET_VOLUME",
            "volume": volume
        ])
    }

    /// Mutes or unmutes the receiver.
    func setMuted(_ muted: Bool) {
        send(namespace: CastNamespace.receiver, payload: [
            "type": "SET_VOLUME",
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

    private func handle(_ message: CastMessage) {
        onMessage?(message)

        guard let payload = try? message.jsonObject() else { return }
        let type = payload["type"] as? String ?? ""

        switch (message.namespace, type) {
        case (CastNamespace.heartbeat, "PING"):
            send(namespace: CastNamespace.heartbeat, payload: ["type": "PONG"])
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            readStatus(payload)
        case (CastNamespace.receiver, "LAUNCH_ERROR"):
            let reason = payload["reason"] as? String ?? "unknown"
            state = .failed("启动接收器失败：\(reason)")
        default:
            break
        }
    }

    private func readStatus(_ payload: [String: Any]) {
        guard let status = payload["status"] as? [String: Any] else { return }
        if let volume = status["volume"] as? [String: Any] {
            let level = volume["level"] as? Double ?? 0
            let muted = volume["muted"] as? Bool ?? false
            onVolumeChange?(level, muted)
        }
        if let applications = status["applications"] as? [[String: Any]] {
            for application in applications {
                if let id = application["appId"] as? String,
                   id == CastDevice.defaultMediaReceiverID {
                    sessionID = application["sessionId"] as? String
                    transportID = application["transportId"] as? String ?? sessionID
                }
            }
        }
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
