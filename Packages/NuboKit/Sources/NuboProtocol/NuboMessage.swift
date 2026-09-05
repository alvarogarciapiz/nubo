import Foundation
import NuboCore

public enum NuboChannel: UInt8, Codable, CaseIterable, Sendable {
    case session = 1
    case video = 2
    case audio = 3
    case input = 4
    case clipboard = 5
    case control = 6
    case statistics = 7
    case configuration = 8
    case preview = 9
}

public struct Handshake: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let deviceID: UUID
    public let deviceName: String
    public let capabilities: Set<Capability>

    public init(
        protocolVersion: UInt16 = NuboConstants.protocolVersion,
        deviceID: UUID,
        deviceName: String,
        capabilities: Set<Capability>
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.capabilities = capabilities
    }
}

public enum Capability: String, Codable, Hashable, Sendable {
    case h264, hevc, aac, clipboardText, relativePointer, multipleDisplays
}

public struct EncodedVideoFrame: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeNanoseconds: UInt64
    public let displayID: DisplayID
    public let isKeyFrame: Bool
    public let bytes: Data

    public init(sequence: UInt64, presentationTimeNanoseconds: UInt64, displayID: DisplayID, isKeyFrame: Bool, bytes: Data) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.displayID = displayID
        self.isKeyFrame = isKeyFrame
        self.bytes = bytes
    }
}

public struct VideoStreamDescriptor: Codable, Equatable, Sendable {
    public let codec: String
    public let width: Int
    public let height: Int
    public let parameterSets: [Data]

    public init(codec: String, width: Int, height: Int, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }
}

public struct EncodedAudioPacket: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeNanoseconds: UInt64
    public let bytes: Data

    public init(sequence: UInt64, presentationTimeNanoseconds: UInt64, bytes: Data) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.bytes = bytes
    }
}

public enum NuboMessage: Codable, Equatable, Sendable {
    case handshake(Handshake)
    case pairingRequest(deviceName: String)
    case pairingResponse(accepted: Bool, credential: Data?)
    case videoConfiguration(VideoStreamDescriptor)
    case videoFrame(EncodedVideoFrame)
    case audioPacket(EncodedAudioPacket)
    case pointer(PointerEvent)
    case key(KeyInputEvent)
    case clipboardText(id: UUID, text: String)
    case displays([DisplayDescriptor])
    case selectDisplay(DisplayID)
    case requestKeyFrame
    case networkStats(ConnectionMetrics)
    case streamConfiguration(StreamConfiguration)
    case preferredVideoCodec(VideoCodec)
    case desktopViewport(width: Int, height: Int, enabled: Bool)
    case desktopViewportStatus(String)
    case previewRequest
    case previewImage(jpeg: Data, capturedAt: Date)
    case ping(UInt64)
    case pong(UInt64)
    case disconnect(reason: String?)

    public var channel: NuboChannel {
        switch self {
        case .handshake, .pairingRequest, .pairingResponse, .disconnect: .session
        case .videoConfiguration, .videoFrame: .video
        case .audioPacket: .audio
        case .pointer, .key: .input
        case .clipboardText: .clipboard
        case .displays, .selectDisplay, .requestKeyFrame, .ping, .pong: .control
        case .networkStats: .statistics
        case .streamConfiguration, .preferredVideoCodec, .desktopViewport, .desktopViewportStatus: .configuration
        case .previewRequest, .previewImage: .preview
        }
    }
}
