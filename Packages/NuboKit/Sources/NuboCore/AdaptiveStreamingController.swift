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
            maximumBitrate: Int = 45_000_000,
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
    private var ceiling: StreamConfiguration
    private var badSamples = 0
    private var goodSamples = 0
    private var lastChange: ContinuousClock.Instant?

    public init(initial: StreamConfiguration = .lanDefault, policy: Policy = .init()) {
        configuration = initial
        ceiling = initial
        if initial.width < StreamConfiguration.lanDefault.width {
            ceiling.width = StreamConfiguration.lanDefault.width
            ceiling.height = max(2, Int(Double(initial.height) * Double(ceiling.width) / Double(initial.width)) & ~1)
            ceiling.framesPerSecond = 60
        }
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

    public func replaceConfiguration(_ newConfiguration: StreamConfiguration) {
        configuration = newConfiguration
        ceiling = newConfiguration
        badSamples = 0
        goodSamples = 0
        lastChange = nil
    }

    private func decreaseQuality() {
        if configuration.bitrate > policy.minimumBitrate {
            configuration.bitrate = max(policy.minimumBitrate, Int(Double(configuration.bitrate) * 0.75))
        } else if configuration.width > min(1_440, ceiling.width) {
            let width = max(min(1_440, ceiling.width), Int(Double(configuration.width) * 0.8) & ~1)
            configuration.height = scaledHeight(forWidth: width)
            configuration.width = width
        } else {
            configuration.framesPerSecond = 30
        }
    }

    private func increaseQuality() {
        if configuration.framesPerSecond < ceiling.framesPerSecond {
            configuration.framesPerSecond = ceiling.framesPerSecond
        } else if configuration.width < ceiling.width {
            configuration.height = ceiling.height
            configuration.width = ceiling.width
        } else {
            configuration.bitrate = min(policy.maximumBitrate, Int(Double(configuration.bitrate) * 1.12))
        }
    }

    private func scaledHeight(forWidth width: Int) -> Int {
        let proportional = Int((Double(configuration.height) * Double(width) / Double(configuration.width)).rounded())
        return max(2, proportional - (proportional % 2))
    }
}
