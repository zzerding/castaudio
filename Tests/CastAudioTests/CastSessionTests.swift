import Foundation
import Testing
@testable import CastAudio

/// The CONNECT payload the device expects during the handshake.
@Test func connectPayloadCarriesTheSenderInfoBlock() throws {
    let payload = CastSession.connectPayload

    #expect(payload["type"] as? String == "CONNECT")
    #expect(payload["userAgent"] as? String != nil)
    #expect(payload["origin"] != nil)
    #expect(payload["senderInfo"] != nil)
}

/// The handshake order matters: the device ignores a LAUNCH that arrives
/// before it has reported its platform status.
@Test func platformReadyFiresOnTheFirstStatusReport() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var readyCount = 0
    session.onPlatformReady = { readyCount += 1 }

    // A status report without any application session.
    let status: [String: Any] = [
        "type": "RECEIVER_STATUS",
        "requestId": 1,
        "status": [
            "volume": ["controlType": "master", "level": 0.5, "muted": false]
        ]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "sender-castaudio",
        namespace: CastNamespace.receiver,
        payload: status
    )

    // The session handles the message through its own message path.
    session.onMessage = { _ in }
    session.handleForTesting(message)

    #expect(readyCount == 1)
}

/// A status report that carries a session must not fire the platform-ready
/// signal again.
@Test func platformReadyFiresOnlyOnce() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var readyCount = 0
    session.onPlatformReady = { readyCount += 1 }

    let status: [String: Any] = [
        "type": "RECEIVER_STATUS",
        "status": ["volume": ["level": 0.5, "muted": false]]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "sender-castaudio",
        namespace: CastNamespace.receiver,
        payload: status
    )
    session.handleForTesting(message)
    session.handleForTesting(message)

    #expect(readyCount == 1)
}

/// The media namespace is only usable after it has been opened for the
/// application session, so the session has to report that separately.
@Test func mediaNamespaceReadyIsReportedWhenASessionAppears() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var readySessions: [String] = []
    session.onMediaNamespaceReady = { readySessions.append($0) }

    let status: [String: Any] = [
        "type": "RECEIVER_STATUS",
        "status": [
            "volume": ["level": 0.5, "muted": false],
            "applications": [[
                "appId": CastDevice.defaultMediaReceiverID,
                "appType": "WEB",
                "displayName": "Default Media Receiver",
                "sessionId": "session-1",
                "transportId": "transport-1"
            ]]
        ]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "*",
        namespace: CastNamespace.receiver,
        payload: status
    )
    session.handleForTesting(message)

    #expect(readySessions == ["session-1"])
    #expect(session.hasMediaSession)
}

/// The volume the device reports is passed on to the listener.
@Test func volumeFromTheDeviceIsReported() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var reported: (Double, Bool)?
    session.onVolumeChange = { level, muted in reported = (level, muted) }

    let status: [String: Any] = [
        "type": "RECEIVER_STATUS",
        "status": ["volume": ["controlType": "master", "level": 0.75, "muted": true]]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "sender-castaudio",
        namespace: CastNamespace.receiver,
        payload: status
    )
    session.handleForTesting(message)

    #expect(reported?.0 == 0.75)
    #expect(reported?.1 == true)
}

/// The player's state is what the console shows as "playing".
@Test func playbackStateIsReportedFromMediaStatus() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var playback: (String, Double)?
    session.onPlaybackStateChange = { state, position in playback = (state, position) }

    let status: [String: Any] = [
        "type": "MEDIA_STATUS",
        "status": [[
            "mediaSessionId": 1,
            "playerState": "PLAYING",
            "currentTime": 12.5,
            "playbackRate": 1
        ]]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "sender-castaudio",
        namespace: CastNamespace.media,
        payload: status
    )
    session.handleForTesting(message)

    #expect(playback?.0 == "PLAYING")
    #expect(playback?.1 == 12.5)
}

/// A SET_VOLUME without a request id is accepted by the device but never
/// applied, so every volume change has to carry one.
@Test func volumeChangeCarriesARequestId() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var sent: [[String: Any]] = []
    session.onMessage = { _ in }
    session.captureOutgoingForTesting { sent.append($0) }

    session.setVolume(level: 0.4)
    session.setMuted(true)

    #expect(sent.count == 2)
    for payload in sent {
        #expect(payload["type"] as? String == "SET_VOLUME")
        #expect(payload["requestId"] != nil)
    }
}

/// The device broadcasts the new volume when it changes from another source.
@Test func deviceUpdateBroadcastIsReported() throws {
    let session = CastSession(device: CastDevice(
        id: "test",
        name: "test",
        endpoint: .hostPort(host: "127.0.0.1", port: 8009)
    ))

    var reported: (Double, Bool)?
    session.onVolumeChange = { level, muted in reported = (level, muted) }

    let payload: [String: Any] = [
        "type": "DEVICE_UPDATED",
        "device": [
            "deviceId": "d08b3654",
            "name": "书房",
            "volume": ["level": 0.25, "muted": false]
        ]
    ]
    let message = try CastMessage.json(
        sourceID: "receiver-0",
        destinationID: "*",
        namespace: CastNamespace.multizone,
        payload: payload
    )
    session.handleForTesting(message)

    #expect(reported?.0 == 0.25)
    #expect(reported?.1 == false)
}
