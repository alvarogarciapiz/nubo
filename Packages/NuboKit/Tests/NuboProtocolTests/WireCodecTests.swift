import Foundation
import NuboCore
@testable import NuboProtocol
import XCTest

final class WireCodecTests: XCTestCase {
    func testRoundTrip() throws {
        let deviceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let message = NuboMessage.handshake(Handshake(
            deviceID: deviceID,
            deviceName: "iPad Pro",
            capabilities: [.h264, .relativePointer]
        ))
        let codec = MessageCodec()
        var decoder = WireDecoder()
        let envelopes = try decoder.append(codec.encode(message))

        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(try codec.decode(envelopes[0]), message)
    }

    func testFragmentedFrameIsBuffered() throws {
        let encoded = try MessageCodec().encode(.ping(42))
        let split = encoded.count / 2
        var decoder = WireDecoder()

        XCTAssertTrue(try decoder.append(encoded.prefix(split)).isEmpty)
        let result = try decoder.append(encoded.suffix(from: split))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(try MessageCodec().decode(result[0]), .ping(42))
    }

    func testMultipleFramesInOneRead() throws {
        let codec = MessageCodec()
        let data = try codec.encode(.ping(1)) + codec.encode(.pong(1))
        var decoder = WireDecoder()
        let result = try decoder.append(data)
        XCTAssertEqual(try result.map(codec.decode), [.ping(1), .pong(1)])
    }

    func testRejectsInvalidMagic() {
        var decoder = WireDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: WireEnvelope.headerLength))) { error in
            XCTAssertEqual(error as? WireCodecError, .invalidMagic)
        }
    }

    func testVideoUsesBinaryPayloadAndRoundTrips() throws {
        let frame = EncodedVideoFrame(
            sequence: 7,
            presentationTimeNanoseconds: 123_456,
            displayID: .init(rawValue: 42),
            isKeyFrame: true,
            bytes: Data(repeating: 0xAB, count: 1_000)
        )
        let codec = MessageCodec()
        let data = try codec.encode(.videoFrame(frame))
        var decoder = WireDecoder()
        let envelope = try XCTUnwrap(decoder.append(data).first)
        XCTAssertEqual(envelope.flags, 1)
        XCTAssertEqual(envelope.payload.count, 1_021)
        XCTAssertEqual(try codec.decode(envelope), .videoFrame(frame))
    }
}
