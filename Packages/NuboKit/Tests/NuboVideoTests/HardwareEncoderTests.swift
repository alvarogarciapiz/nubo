import CoreMedia
import CoreVideo
import NuboCore
import NuboVideo
import VideoToolbox
import XCTest

final class HardwareEncoderTests: XCTestCase {
    /// This intentionally exercises VideoToolbox, not ScreenCaptureKit or TCC.
    /// Run on Apple hardware; virtual CI without an encoder skips explicitly.
    func testHardwareEncoderProducesInitialRetinaKeyframe() throws {
        try roundTrip(codec: .h264)
    }

    func testHEVCHardwareRoundTrip() throws {
        guard LowLatencyH264Decoder.supportsHEVC else { throw XCTSkip("HEVC hardware decoding unavailable") }
        try roundTrip(codec: .hevc)
    }

    private func roundTrip(codec: VideoCodec) throws {
        let ready = expectation(description: "Initial hardware-encoded keyframe")
        let decoded = expectation(description: "Decoded Retina frame")
        let decoder = LowLatencyH264Decoder { buffer, _ in
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 2732)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 2048)
            decoded.fulfill()
        }
        defer { decoder.invalidate() }
        let encoder: LowLatencyH264Encoder
        do {
            encoder = try LowLatencyH264Encoder(configuration: .init(
                width: 2732, height: 2048, framesPerSecond: 60, bitrate: 30_000_000, keyFrameInterval: 120
            ), codec: codec) { packet in
                if packet.isKeyFrame && !packet.parameterSets.isEmpty && !packet.data.isEmpty { ready.fulfill() }
                do {
                    try decoder.configure(parameterSets: packet.parameterSets, codec: codec)
                    try decoder.decode(packet)
                } catch { XCTFail("Hardware round trip failed: \(error)") }
            }
        } catch VideoEncoderError.sessionCreation(let status) where status == kVTCouldNotFindVideoEncoderErr || status == kVTVideoEncoderNotAvailableNowErr {
            throw XCTSkip("Hardware encoder unavailable on this runner (\(status))")
        }
        defer { encoder.invalidate() }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2732, 2048,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            if let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(address, plane == 0 ? 16 : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try encoder.encode(buffer, presentationTime: .zero)
        wait(for: [ready, decoded], timeout: 5)
    }
}
