import Foundation

/// One Cast V2 protocol message.
///
/// Field numbers follow the `CastMessage` message defined by Chromium in
/// `extensions/common/api/cast_channel/cast_channel.proto`:
///
/// ```protobuf
/// message CastMessage {
///   enum ProtocolVersion { CASTV2_1_0 = 0; }
///   required ProtocolVersion protocol_version = 1;
///   required string source_id = 2;
///   required string destination_id = 3;
///   required string namespace = 4;
///   enum PayloadType { STRING = 0; BINARY = 1; }
///   required PayloadType payload_type = 5;
///   optional string payload_utf8 = 6;
///   optional bytes payload_binary = 7;
/// }
/// ```
struct CastMessage {
    enum PayloadType: UInt32 {
        case string = 0
        case binary = 1
    }

    var protocolVersion: UInt32 = 0
    var sourceID: String
    var destinationID: String
    var namespace: String
    var payloadType: PayloadType = .string
    var payloadUTF8: String?
    var payloadBinary: Data?

    init(
        sourceID: String,
        destinationID: String,
        namespace: String,
        payloadType: PayloadType = .string,
        payloadUTF8: String? = nil,
        payloadBinary: Data? = nil
    ) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payloadType = payloadType
        self.payloadUTF8 = payloadUTF8
        self.payloadBinary = payloadBinary
    }

    /// Builds a message whose payload is a JSON object.
    static func json(
        sourceID: String,
        destinationID: String,
        namespace: String,
        payload: [String: Any]
    ) throws -> CastMessage {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CastMessageError.payloadNotUTF8
        }
        return CastMessage(
            sourceID: sourceID,
            destinationID: destinationID,
            namespace: namespace,
            payloadType: .string,
            payloadUTF8: text
        )
    }

    /// The JSON payload, parsed into an object.
    func jsonObject() throws -> [String: Any] {
        guard let payloadUTF8 else {
            throw CastMessageError.missingStringPayload
        }
        guard let data = payloadUTF8.data(using: .utf8) else {
            throw CastMessageError.payloadNotUTF8
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw CastMessageError.payloadNotObject
        }
        return dictionary
    }

    // MARK: - Encoding

    /// The protobuf encoding of this message.
    func encoded() -> Data {
        var writer = Protobuf.Writer()
        writer.writeUInt32(fieldNumber: 1, value: protocolVersion)
        writer.writeString(fieldNumber: 2, value: sourceID)
        writer.writeString(fieldNumber: 3, value: destinationID)
        writer.writeString(fieldNumber: 4, value: namespace)
        writer.writeUInt32(fieldNumber: 5, value: payloadType.rawValue)
        if let payloadUTF8 {
            writer.writeString(fieldNumber: 6, value: payloadUTF8)
        }
        if let payloadBinary {
            writer.writeBytes(fieldNumber: 7, value: payloadBinary)
        }
        return writer.data
    }

    /// The bytes that go on the wire: a 32-bit big-endian length followed by
    /// the protobuf encoding.
    func framed() -> Data {
        let payload = encoded()
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    // MARK: - Decoding

    /// Parses a protobuf-encoded `CastMessage`.
    static func decode(_ data: Data) throws -> CastMessage {
        var reader = Protobuf.Reader(data)
        var protocolVersion: UInt32 = 0
        var sourceID: String?
        var destinationID: String?
        var namespace: String?
        var payloadType: PayloadType = .string
        var payloadUTF8: String?
        var payloadBinary: Data?

        while let tag = try reader.nextTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint):
                protocolVersion = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (2, .lengthDelimited):
                sourceID = String(data: try reader.readLengthDelimited(), encoding: .utf8)
            case (3, .lengthDelimited):
                destinationID = String(data: try reader.readLengthDelimited(), encoding: .utf8)
            case (4, .lengthDelimited):
                namespace = String(data: try reader.readLengthDelimited(), encoding: .utf8)
            case (5, .varint):
                let raw = UInt32(truncatingIfNeeded: try reader.readVarint())
                payloadType = PayloadType(rawValue: raw) ?? .string
            case (6, .lengthDelimited):
                payloadUTF8 = String(data: try reader.readLengthDelimited(), encoding: .utf8)
            case (7, .lengthDelimited):
                payloadBinary = try reader.readLengthDelimited()
            default:
                try reader.skip(wireType: tag.wireType)
            }
        }

        guard let sourceID, let destinationID, let namespace else {
            throw CastMessageError.missingRequiredField
        }
        return CastMessage(
            sourceID: sourceID,
            destinationID: destinationID,
            namespace: namespace,
            payloadType: payloadType,
            payloadUTF8: payloadUTF8,
            payloadBinary: payloadBinary
        )
    }

    /// Splits a stream of bytes into whole messages, using the length
    /// prefix. Returns the messages that are complete and the bytes that are
    /// still incomplete.
    static func decodeFramed(
        _ buffer: inout Data
    ) throws -> [CastMessage] {
        var messages: [CastMessage] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(MemoryLayout<UInt32>.size).withUnsafeBytes { raw -> UInt32 in
                UInt32(bigEndian: raw.load(as: UInt32.self))
            }
            // A length of zero would mean an empty protobuf message; treat
            // anything implausible as a protocol error rather than waiting
            // for bytes that will never arrive.
            guard length > 0, length <= 1 << 22 else {
                throw CastMessageError.invalidFrameLength(Int(length))
            }
            let total = MemoryLayout<UInt32>.size + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: MemoryLayout<UInt32>.size..<total)
            buffer.removeSubrange(0..<total)
            messages.append(try decode(payload))
        }
        return messages
    }
}

enum CastMessageError: Error {
    case payloadNotUTF8
    case payloadNotObject
    case missingStringPayload
    case missingRequiredField
    case invalidFrameLength(Int)
}
