import NuboCore
import XCTest

final class AdaptiveStreamingTests: XCTestCase {
    func testBadNetworkReducesBitrateBeforeResolutionAndFPS() async {
        let policy = AdaptiveStreamingController.Policy(
            minimumBitrate: 3_000_000,
            maximumBitrate: 25_000_000,
            badSamplesBeforeDecrease: 1,
            goodSamplesBeforeIncrease: 1,
            cooldown: .zero
        )
        let controller = AdaptiveStreamingController(initial: .lanDefault, policy: policy)
        let bad = ConnectionMetrics(rttMilliseconds: 120, jitterMilliseconds: 30, packetLoss: 0.04)

        let first = await controller.ingest(bad)
        XCTAssertEqual(first?.bitrate, 9_000_000)
        XCTAssertEqual(first?.width, 1_920)
        XCTAssertEqual(first?.framesPerSecond, 60)
    }

    func testQualityRecoversInReverseOrder() async {
        let initial = StreamConfiguration(width: 1_440, height: 900, framesPerSecond: 30, bitrate: 3_000_000)
        let policy = AdaptiveStreamingController.Policy(goodSamplesBeforeIncrease: 1, cooldown: .zero)
        let controller = AdaptiveStreamingController(initial: initial, policy: policy)
        let good = ConnectionMetrics(rttMilliseconds: 4, jitterMilliseconds: 1, packetLoss: 0)

        let frameRateRecovery = await controller.ingest(good)
        let resolutionRecovery = await controller.ingest(good)
        let bitrateRecovery = await controller.ingest(good)
        XCTAssertEqual(frameRateRecovery?.framesPerSecond, 60)
        XCTAssertEqual(resolutionRecovery?.width, 1_920)
        XCTAssertEqual(bitrateRecovery?.bitrate, 3_360_000)
    }
}
