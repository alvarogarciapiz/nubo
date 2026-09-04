import Foundation

public enum NuboConstants {
    public static let serviceType = "_nubo._tcp"
    public static let defaultPort: UInt16 = 49_832
    public static let protocolVersion: UInt16 = 1
}

public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct DisplayDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: DisplayID
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let originX: Double
    public let originY: Double
    public let isPrimary: Bool

    public init(
        id: DisplayID,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        originX: Double,
        originY: Double,
        isPrimary: Bool
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.originX = originX
        self.originY = originY
        self.isPrimary = isPrimary
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case pairing(code: String)
    case connected
    case reconnecting(attempt: Int)
    case unavailable(reason: String)
}

public struct StreamConfiguration: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var bitrate: Int
    public var keyFrameInterval: Int

    public init(width: Int, height: Int, framesPerSecond: Int, bitrate: Int, keyFrameInterval: Int = 120) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.keyFrameInterval = keyFrameInterval
    }

    public static let lanDefault = StreamConfiguration(
        width: 1_920,
        height: 1_200,
        framesPerSecond: 60,
        bitrate: 12_000_000
    )
}

public struct ConnectionMetrics: Codable, Equatable, Sendable {
    public var rttMilliseconds: Double
    public var jitterMilliseconds: Double
    public var bitrate: Int
    public var packetLoss: Double
    public var framesPerSecond: Double
    public var droppedFrames: Int
    public var encodeLatencyMilliseconds: Double
    public var decodeLatencyMilliseconds: Double
    public var renderLatencyMilliseconds: Double

    public init(
        rttMilliseconds: Double = 0,
        jitterMilliseconds: Double = 0,
        bitrate: Int = 0,
        packetLoss: Double = 0,
        framesPerSecond: Double = 0,
        droppedFrames: Int = 0,
        encodeLatencyMilliseconds: Double = 0,
        decodeLatencyMilliseconds: Double = 0,
        renderLatencyMilliseconds: Double = 0
    ) {
        self.rttMilliseconds = rttMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.bitrate = bitrate
        self.packetLoss = packetLoss
        self.framesPerSecond = framesPerSecond
        self.droppedFrames = droppedFrames
        self.encodeLatencyMilliseconds = encodeLatencyMilliseconds
        self.decodeLatencyMilliseconds = decodeLatencyMilliseconds
        self.renderLatencyMilliseconds = renderLatencyMilliseconds
    }
}
