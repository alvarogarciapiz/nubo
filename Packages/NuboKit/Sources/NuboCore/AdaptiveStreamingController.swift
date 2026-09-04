import Foundation

public actor AdaptiveStreamingController {
    public struct Policy: Sendable {
        public let minimumBitrate: Int
        public let maximumBitrate: Int
        public let badSamplesBeforeDecrease: Int
        public let goodSamplesBeforeIncrease: Int
        public let cooldown: Duration

        public init(
            minimumBitrate: Int = 3_000_000,
            maximumBitrate: Int = 25_000_000,
            badSamplesBeforeDecrease: Int = 3,
            goodSamplesBeforeIncrease: Int = 10,
            cooldown: Duration = .seconds(3)
        ) {
            self.minimumBitrate = minimumBitrate
            self.maximumBitrate = maximumBitrate
            self.badSamplesBeforeDecrease = badSamplesBeforeDecrease
            self.goodSamplesBeforeIncrease = goodSamplesBeforeIncrease
            self.cooldown = cooldown
        }
    }

    private let policy: Policy
    private let clock = ContinuousClock()
    private var configuration: StreamConfiguration
    private var badSamples = 0
    private var goodSamples = 0
    private var lastChange: ContinuousClock.Instant?

    public init(initial: StreamConfiguration = .lanDefault, policy: Policy = .init()) {
        configuration = initial
        self.policy = policy
    }

    public func ingest(_ metrics: ConnectionMetrics) -> StreamConfiguration? {
        let isBad = metrics.packetLoss > 0.025 || metrics.rttMilliseconds > 90 || metrics.jitterMilliseconds > 25
        let isGood = metrics.packetLoss < 0.005 && metrics.rttMilliseconds < 35 && metrics.jitterMilliseconds < 8

        badSamples = isBad ? badSamples + 1 : 0
        goodSamples = isGood ? goodSamples + 1 : 0

        if let lastChange, clock.now - lastChange < policy.cooldown {
            return nil
        }

        if badSamples >= policy.badSamplesBeforeDecrease {
            badSamples = 0
            goodSamples = 0
            decreaseQuality()
            lastChange = clock.now
            return configuration
        }

        if goodSamples >= policy.goodSamplesBeforeIncrease {
            badSamples = 0
            goodSamples = 0
            increaseQuality()
            lastChange = clock.now
            return configuration
        }

        return nil
    }

    public func currentConfiguration() -> StreamConfiguration {
        configuration
    }

    private func decreaseQuality() {
        if configuration.bitrate > policy.minimumBitrate {
            configuration.bitrate = max(policy.minimumBitrate, Int(Double(configuration.bitrate) * 0.75))
        } else if configuration.width > 1_440 {
            configuration.width = 1_440
            configuration.height = 900
        } else {
            configuration.framesPerSecond = 30
        }
    }

    private func increaseQuality() {
        if configuration.framesPerSecond < 60 {
            configuration.framesPerSecond = 60
        } else if configuration.width < 1_920 {
            configuration.width = 1_920
            configuration.height = 1_200
        } else {
            configuration.bitrate = min(policy.maximumBitrate, Int(Double(configuration.bitrate) * 1.12))
        }
    }
}
