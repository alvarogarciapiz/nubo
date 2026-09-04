import CoreMedia
import Foundation

public enum AudioCodec: String, Codable, Sendable {
    case aacLowComplexity
}

public struct AudioConfiguration: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bitrate: Int

    public init(sampleRate: Double = 48_000, channelCount: Int = 2, bitrate: Int = 128_000) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitrate = bitrate
    }
}

public protocol AudioEncoding: AnyObject, Sendable {
    func encode(_ sampleBuffer: CMSampleBuffer) throws
    func invalidate()
}

public protocol AudioDecoding: AnyObject, Sendable {
    func decode(_ data: Data, presentationTime: CMTime) throws
    func invalidate()
}
