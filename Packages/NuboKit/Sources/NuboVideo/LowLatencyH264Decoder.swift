import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

public final class LowLatencyH264Decoder: VideoDecoding, @unchecked Sendable {
    public typealias Output = @Sendable (CVPixelBuffer, CMTime) -> Void

    private let lock = NSLock()
    private let output: Output
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    public init(output: @escaping Output) {
        self.output = output
    }

    public func configure(parameterSets: [Data]) throws {
        guard parameterSets.count >= 2 else { throw VideoEncoderError.property(-1, "Missing H.264 parameter sets") }
        let nsData = parameterSets.map { $0 as NSData }
        let pointers = nsData.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = nsData.map(\.length)
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw VideoEncoderError.property(status, "H.264 format") }
        invalidate()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true] as CFDictionary,
            imageBufferAttributes: attributes,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else { throw VideoEncoderError.sessionCreation(sessionStatus) }
        self.formatDescription = format
        lock.withLock { self.session = session }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    public func decode(_ packet: VideoPacket) throws {
        guard let formatDescription, let session = lock.withLock({ self.session }) else { return }
        guard !packet.data.isEmpty else { return }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw VideoEncoderError.encode(status) }
        status = packet.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw VideoEncoderError.encode(status) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: packet.presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = packet.data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw VideoEncoderError.encode(status) }
        var flags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: &flags)
        guard status == noErr else { throw VideoEncoderError.encode(status) }
    }

    public func invalidate() {
        let old = lock.withLock { () -> VTDecompressionSession? in defer { session = nil }; return session }
        if let old {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
        }
    }

    deinit { invalidate() }

    private static let callback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTime, _ in
        guard status == noErr, let refcon, let imageBuffer else { return }
        Unmanaged<LowLatencyH264Decoder>.fromOpaque(refcon).takeUnretainedValue().output(imageBuffer, presentationTime)
    }
}
