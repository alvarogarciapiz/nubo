import CoreMedia
import CoreVideo
import Foundation
import NuboCore
@preconcurrency import VideoToolbox

public enum VideoEncoderError: LocalizedError {
    case sessionCreation(OSStatus)
    case property(OSStatus, String)
    case encode(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .sessionCreation(status): "Hardware video encoder could not start (\(status))."
        case let .property(status, key): "Video encoder rejected \(key) (\(status))."
        case let .encode(status): "Video frame encoding failed (\(status))."
        }
    }
}

public final class LowLatencyH264Encoder: VideoEncoding, @unchecked Sendable {
    public typealias Output = @Sendable (VideoPacket) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var configuration: StreamConfiguration
    private var forceNextKeyFrame = false
    private let output: Output
    public let codec: VideoCodec

    public init(configuration: StreamConfiguration, codec: VideoCodec = .h264, output: @escaping Output) throws {
        self.codec = codec
        self.configuration = configuration
        self.output = output
        try createSession(configuration: configuration)
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        let (session, framesPerSecond, forceKeyFrame) = lock.withLock {
            let request = forceNextKeyFrame
            forceNextKeyFrame = false
            return (self.session, configuration.framesPerSecond, request)
        }
        guard let session else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        let frameProperties = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else { throw VideoEncoderError.encode(status) }
    }

    /// Forces the next submitted frame to be independently decodable. This is
    /// used after network backpressure drops an encoded inter-frame.
    public func requestKeyFrame() {
        lock.withLock { forceNextKeyFrame = true }
    }

    public func update(configuration: StreamConfiguration) throws {
        let needsRebuild = lock.withLock {
            let rebuild = configuration.width != self.configuration.width || configuration.height != self.configuration.height
            self.configuration = configuration
            return rebuild
        }
        if needsRebuild {
            invalidate()
            try createSession(configuration: configuration)
        } else if let session = lock.withLock({ self.session }) {
            try set(configuration.bitrate, key: kVTCompressionPropertyKey_AverageBitRate, on: session)
            try set(configuration.framesPerSecond, key: kVTCompressionPropertyKey_ExpectedFrameRate, on: session)
        }
    }

    public func invalidate() {
        let oldSession = lock.withLock { () -> VTCompressionSession? in
            defer { session = nil }
            return session
        }
        if let oldSession {
            VTCompressionSessionCompleteFrames(oldSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(oldSession)
        }
    }

    deinit { invalidate() }

    private func createSession(configuration: StreamConfiguration) throws {
        var newSession: VTCompressionSession?
        let specification = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { throw VideoEncoderError.sessionCreation(status) }
        try set(true, key: kVTCompressionPropertyKey_RealTime, on: newSession)
        try set(false, key: kVTCompressionPropertyKey_AllowFrameReordering, on: newSession)
        // Hardware support for these tuning hints varies. An unsupported hint
        // must not prevent an otherwise valid hardware encoder from starting.
        _ = VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        _ = VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        try set(configuration.framesPerSecond, key: kVTCompressionPropertyKey_ExpectedFrameRate, on: newSession)
        try set(configuration.bitrate, key: kVTCompressionPropertyKey_AverageBitRate, on: newSession)
        try set(configuration.keyFrameInterval, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, on: newSession)
        try set(codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel, key: kVTCompressionPropertyKey_ProfileLevel, on: newSession)
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        lock.withLock { session = newSession }
    }

    private func set(_ value: Any, key: CFString, on session: VTCompressionSession) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        guard status == noErr else { throw VideoEncoderError.property(status, key as String) }
    }

    private static let compressionCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard blockStatus == noErr, let pointer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        let parameterSets = isKeyFrame ? LowLatencyH264Encoder.h264ParameterSets(from: sampleBuffer.formatDescription) : []
        let encoder = Unmanaged<LowLatencyH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.output(VideoPacket(
            data: Data(bytes: pointer, count: length),
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets
        ))
    }

    private static func h264ParameterSets(from formatDescription: CMFormatDescription?) -> [Data] {
        guard let formatDescription else { return [] }
        if CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC {
            var count = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            return (0..<count).compactMap { index in
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                return Data(bytes: pointer, count: size)
            }
        }
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
