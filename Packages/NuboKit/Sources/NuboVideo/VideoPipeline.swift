import CoreMedia
import CoreVideo
import Foundation
import NuboCore

public enum VideoCodec: String, Codable, Sendable {
    case h264
    case hevc
}

public struct VideoPacket: @unchecked Sendable {
    public let data: Data
    public let presentationTime: CMTime
    public let isKeyFrame: Bool
    public let parameterSets: [Data]

    public init(data: Data, presentationTime: CMTime, isKeyFrame: Bool, parameterSets: [Data] = []) {
        self.data = data
        self.presentationTime = presentationTime
        self.isKeyFrame = isKeyFrame
        self.parameterSets = parameterSets
    }
}

public protocol VideoEncoding: AnyObject, Sendable {
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws
    func update(configuration: StreamConfiguration) throws
    func invalidate()
}

public protocol VideoDecoding: AnyObject, Sendable {
    func decode(_ packet: VideoPacket) throws
    func invalidate()
}

/// A lock-protected single-slot mailbox. Producers replace an unrendered frame;
/// consumers always receive the freshest frame instead of building latency.
public final class LatestFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?

    public init() {}

    public func submit(_ frame: CVPixelBuffer) {
        lock.withLock { self.frame = frame }
    }

    public func take() -> CVPixelBuffer? {
        lock.withLock {
            defer { frame = nil }
            return frame
        }
    }
}
