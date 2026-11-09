import Foundation

/// Minimal protobuf wire-format reader and writer.
///
/// The Cast V2 channel uses one protobuf message (`CastMessage`) with a
/// handful of scalar fields, so the wire format is implemented here rather
/// than pulling in a protobuf runtime as a package dependency.
enum Protobuf {
    // MARK: - Wire types

    enum WireType: UInt32 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    // MARK: - Writer

    struct Writer {
        private(set) var data = Data()

        mutating func writeVarint(_ value: UInt64) {
            var remaining = value
            repeat {
                var byte = UInt8(remaining & 0x7F)
                remaining >>= 7
                if remaining != 0 { byte |= 0x80 }
                data.append(byte)
            } while remaining != 0
        }

        mutating func writeTag(fieldNumber: Int, wireType: WireType) {
            writeVarint(UInt64(fieldNumber) << 3 | UInt64(wireType.rawValue))
        }

        mutating func writeUInt32(fieldNumber: Int, value: UInt32) {
            writeTag(fieldNumber: fieldNumber, wireType: .varint)
            writeVarint(UInt64(value))
        }

        mutating func writeString(fieldNumber: Int, value: String) {
            writeBytes(fieldNumber: fieldNumber, value: Data(value.utf8))
        }

        mutating func writeBytes(fieldNumber: Int, value: Data) {
            writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
            writeVarint(UInt64(value.count))
            data.append(value)
        }
    }

    // MARK: - Reader

    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) {
            self.bytes = [UInt8](data)
        }

        var isAtEnd: Bool { offset >= bytes.count }

        /// Reads the next field header. Returns nil when the buffer is
        /// exhausted.
        mutating func nextTag() throws -> (fieldNumber: Int, wireType: WireType)? {
            guard !isAtEnd else { return nil }
            let key = try readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = WireType(rawValue: UInt32(key & 0x07))
            guard let wireType else {
                throw ProtobufError.invalidWireType(Int(key & 0x07))
            }
            guard fieldNumber > 0 else {
                throw ProtobufError.invalidFieldNumber(fieldNumber)
            }
            return (fieldNumber, wireType)
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count else { throw ProtobufError.truncated }
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                if shift > 63 { throw ProtobufError.varintOverflow }
            }
            return result
        }

        mutating func readLengthDelimited() throws -> Data {
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw ProtobufError.truncated }
            let count = Int(length)
            guard offset + count <= bytes.count else { throw ProtobufError.truncated }
            let slice = Data(bytes[offset..<(offset + count)])
            offset += count
            return slice
        }

        /// Skips a field the reader does not know about, so that unknown
        /// fields in a future protocol revision do not break parsing.
        mutating func skip(wireType: WireType) throws {
            switch wireType {
            case .varint:
                _ = try readVarint()
            case .fixed64:
                guard offset + 8 <= bytes.count else { throw ProtobufError.truncated }
                offset += 8
            case .lengthDelimited:
                _ = try readLengthDelimited()
            case .fixed32:
                guard offset + 4 <= bytes.count else { throw ProtobufError.truncated }
                offset += 4
            }
        }
    }

    enum ProtobufError: Error {
        case truncated
        case varintOverflow
        case invalidWireType(Int)
        case invalidFieldNumber(Int)
    }
}
