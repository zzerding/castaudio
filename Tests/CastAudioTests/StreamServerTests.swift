import Foundation
import Testing
@testable import CastAudio

// CRLF as raw bytes, so the expectations do not depend on how the source
// file escapes are read.
private let crlf = Data([0x0D, 0x0A])

/// The stream server answers with `Transfer-Encoding: chunked`, so every
/// payload has to be wrapped in a chunk header. A Cast device's media stack
/// parses the response as HTTP: unframed bytes are read as a broken response
/// instead of as audio.
@Test func streamServerFramesPayloadsAsHTTPChunks() {
    let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    let chunk = AudioStreamServer.chunkFraming(payload)

    // Header: length in lower-case hex, then CRLF.
    var expectedHeader = Data([0x35])
    expectedHeader.append(crlf)
    #expect(chunk.prefix(expectedHeader.count) == expectedHeader)

    // Payload follows the header.
    let payloadStart = expectedHeader.count
    #expect(chunk.subdata(in: payloadStart..<(payloadStart + payload.count)) == payload)

    // Trailer: CRLF.
    #expect(chunk.suffix(crlf.count) == crlf)

    #expect(chunk.count == payload.count + expectedHeader.count + crlf.count)
}

@Test func streamServerChunkLengthMatchesPayloadForLargerFrames() {
    let payload = Data(repeating: 0xAB, count: 4096)
    let chunk = AudioStreamServer.chunkFraming(payload)

    // 4096 is "1000" in hex, so the header is four hex digits plus CRLF.
    var expectedHeader = Data([0x31, 0x30, 0x30, 0x30])
    expectedHeader.append(crlf)
    #expect(chunk.prefix(expectedHeader.count) == expectedHeader)
    #expect(chunk.count == payload.count + expectedHeader.count + crlf.count)
}
