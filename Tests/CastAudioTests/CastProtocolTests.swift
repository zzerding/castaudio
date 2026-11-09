import Foundation
import Testing
@testable import CastAudio

/// Builds a protobuf-free reference encoding to compare against.
private func expectedVarint(_ value: UInt64) -> [UInt8] {
    var bytes: [UInt8] = []
    var remaining = value
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while remaining != 0
    return bytes
}

private func expectedTag(fieldNumber: Int, wireType: Int) -> [UInt8] {
    expectedVarint(UInt64(fieldNumber << 3 | wireType))
}

private func expectedLengthDelimited(fieldNumber: Int, text: String) -> [UInt8] {
    var bytes = expectedTag(fieldNumber: fieldNumber, wireType: 2)
    let payload = [UInt8](text.utf8)
    bytes += expectedVarint(UInt64(payload.count))
    bytes += payload
    return bytes
}

@Test func castMessageUsesTheDocumentedFieldNumbers() throws {
    let message = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.connection,
        payloadUTF8: "{\"type\":\"CONNECT\"}"
    )
    let bytes = [UInt8](message.encoded())

    var expected: [UInt8] = []
    expected += expectedTag(fieldNumber: 1, wireType: 0)
    expected += expectedVarint(0)              // protocol_version = CASTV2_1_0
    expected += expectedLengthDelimited(fieldNumber: 2, text: "sender-0")
    expected += expectedLengthDelimited(fieldNumber: 3, text: "receiver-0")
    expected += expectedLengthDelimited(fieldNumber: 4, text: CastNamespace.connection)
    expected += expectedTag(fieldNumber: 5, wireType: 0)
    expected += expectedVarint(0)              // payload_type = STRING
    expected += expectedLengthDelimited(fieldNumber: 6, text: "{\"type\":\"CONNECT\"}")

    #expect(bytes == expected)
}

@Test func castMessageFrameIsBigEndianLengthFollowedByPayload() throws {
    let message = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.heartbeat,
        payloadUTF8: "{\"type\":\"PING\"}"
    )
    let frame = message.framed()
    let payload = message.encoded()

    #expect(frame.count == payload.count + 4)
    let length = frame.prefix(4).withUnsafeBytes { raw -> UInt32 in
        UInt32(bigEndian: raw.load(as: UInt32.self))
    }
    #expect(Int(length) == payload.count)
    #expect(frame.dropFirst(4) == payload)
}

@Test func castMessageRoundTripsThroughProtobuf() throws {
    let original = CastMessage(
        sourceID: "sender-castaudio",
        destinationID: "receiver-0",
        namespace: CastNamespace.receiver,
        payloadType: .string,
        payloadUTF8: "{\"type\":\"GET_STATUS\",\"requestId\":1}"
    )
    let decoded = try CastMessage.decode(original.encoded())

    #expect(decoded.sourceID == original.sourceID)
    #expect(decoded.destinationID == original.destinationID)
    #expect(decoded.namespace == original.namespace)
    #expect(decoded.payloadType == original.payloadType)
    #expect(decoded.payloadUTF8 == original.payloadUTF8)
}

@Test func castMessageDecodesBinaryPayloads() throws {
    var writer = Protobuf.Writer()
    writer.writeUInt32(fieldNumber: 1, value: 0)
    writer.writeString(fieldNumber: 2, value: "sender-0")
    writer.writeString(fieldNumber: 3, value: "receiver-0")
    writer.writeString(fieldNumber: 4, value: CastNamespace.deviceAuth)
    writer.writeUInt32(fieldNumber: 5, value: 1)  // BINARY
    writer.writeBytes(fieldNumber: 7, value: Data([0xDE, 0xAD, 0xBE, 0xEF]))

    let decoded = try CastMessage.decode(writer.data)
    #expect(decoded.payloadType == .binary)
    #expect(decoded.payloadBinary == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    #expect(decoded.payloadUTF8 == nil)
}

@Test func framedDecoderWaitsForTheWholeMessage() throws {
    let message = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.connection,
        payloadUTF8: "{\"type\":\"CONNECT\"}"
    )
    let frame = message.framed()

    // Feed the frame one byte at a time; nothing decodes until the last byte
    // of the length prefix and payload have arrived.
    var buffer = Data()
    for byte in frame.dropLast() {
        buffer.append(byte)
        #expect(try CastMessage.decodeFramed(&buffer).isEmpty)
    }
    buffer.append(frame.last!)
    let messages = try CastMessage.decodeFramed(&buffer)
    #expect(messages.count == 1)
    #expect(messages.first?.payloadUTF8 == "{\"type\":\"CONNECT\"}")
    #expect(buffer.isEmpty)
}

@Test func framedDecoderSplitsConcatenatedMessages() throws {
    let first = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.connection,
        payloadUTF8: "{\"type\":\"CONNECT\"}"
    )
    let second = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.heartbeat,
        payloadUTF8: "{\"type\":\"PING\"}"
    )
    var buffer = first.framed()
    buffer.append(second.framed())

    let messages = try CastMessage.decodeFramed(&buffer)
    #expect(messages.count == 2)
    #expect(messages[0].namespace == CastNamespace.connection)
    #expect(messages[1].namespace == CastNamespace.heartbeat)
}

@Test func jsonPayloadBuildsAndParses() throws {
    let message = try CastMessage.json(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.receiver,
        payload: [
            "type": "LAUNCH",
            "appId": CastDevice.defaultMediaReceiverID,
            "requestId": 3
        ]
    )
    let object = try message.jsonObject()
    #expect(object["type"] as? String == "LAUNCH")
    #expect(object["appId"] as? String == "CC1AD845")
    #expect(object["requestId"] as? Int == 3)
}

@Test func protobufVarintMatchesTheReferenceEncoding() {
    #expect(expectedVarint(0) == [0x00])
    #expect(expectedVarint(1) == [0x01])
    #expect(expectedVarint(127) == [0x7F])
    #expect(expectedVarint(128) == [0x80, 0x01])
    #expect(expectedVarint(300) == [0xAC, 0x02])
}
