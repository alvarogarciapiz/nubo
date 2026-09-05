import NuboCore
import XCTest

final class StreamingQualityTests: XCTestCase {
    func testAutomaticPreservesIPadRetinaPixels() {
        let config = StreamingQuality.configuration(quality: "automatic", pixelWidth: 2732, pixelHeight: 2048, frameRate: "automatic")
        XCTAssertEqual(config.width, 2732)
        XCTAssertEqual(config.height, 2048)
        XCTAssertGreaterThan(config.bitrate, 25_000_000)
    }

    func testPortraitAndWindowSizesStayEvenAndBounded() {
        let config = StreamingQuality.configuration(quality: "high", pixelWidth: 2049, pixelHeight: 4097, frameRate: "30")
        XCTAssertEqual(config.height, 3200)
        XCTAssertEqual(config.width % 2, 0)
        XCTAssertEqual(config.framesPerSecond, 30)
        XCTAssertLessThanOrEqual(config.bitrate, 45_000_000)
    }

    func testAdaptationRecoversRequestedRetinaResolutionAndRespects30FPS() async {
        let ceiling = StreamConfiguration(width: 3000, height: 2000, framesPerSecond: 30, bitrate: 3_000_000)
        let controller = AdaptiveStreamingController(policy: .init(badSamplesBeforeDecrease: 1, goodSamplesBeforeIncrease: 1, cooldown: .zero))
        await controller.replaceConfiguration(ceiling)
        let reduced = await controller.ingest(.init(rttMilliseconds: 120))
        XCTAssertLessThan(reduced?.width ?? 3000, 3000)
        let recovered = await controller.ingest(.init(rttMilliseconds: 4))
        XCTAssertEqual(recovered?.width, 3000)
        XCTAssertEqual(recovered?.height, 2000)
        XCTAssertEqual(recovered?.framesPerSecond, 30)
    }
}
