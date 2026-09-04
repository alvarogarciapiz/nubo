import Foundation
import NuboProtocol

public enum TransportKind: String, Sendable {
    case encryptedLowLatencyTCP
    case quicDatagramFuture
}

public struct ChannelTransportPlan: Equatable, Sendable {
    public let channel: NuboChannel
    public let transport: TransportKind
    public let dropsStaleMessages: Bool

    public static let lowLatencyDefault: [ChannelTransportPlan] = [
        .init(channel: .session, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .control, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .input, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .clipboard, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .configuration, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .statistics, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false),
        .init(channel: .video, transport: .encryptedLowLatencyTCP, dropsStaleMessages: true),
        .init(channel: .audio, transport: .encryptedLowLatencyTCP, dropsStaleMessages: false)
    ]
}
