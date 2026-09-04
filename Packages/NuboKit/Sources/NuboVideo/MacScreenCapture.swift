#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import NuboCore
@preconcurrency import ScreenCaptureKit

public enum ScreenCaptureError: Error {
    case displayNotFound(DisplayID)
}

public final class MacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias VideoOutput = @Sendable (CVPixelBuffer, CMTime) -> Void
    public typealias AudioOutput = @Sendable (CMSampleBuffer) -> Void

    private let queue = DispatchQueue(label: "com.lvrpiz.nubo.capture", qos: .userInteractive)
    private let videoOutput: VideoOutput
    private let audioOutput: AudioOutput?
    private var stream: SCStream?

    public init(videoOutput: @escaping VideoOutput, audioOutput: AudioOutput? = nil) {
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
    }

    public func availableDisplays() async throws -> [DisplayDescriptor] {
        let content = try await SCShareableContent.current
        return content.displays.map { display in
            let scale = display.frame.width > 0 ? Double(display.width) / display.frame.width : 1
            return DisplayDescriptor(
                id: DisplayID(rawValue: display.displayID),
                name: "Display \(display.displayID)",
                pixelWidth: display.width,
                pixelHeight: display.height,
                scale: scale,
                originX: Double(display.frame.origin.x),
                originY: Double(display.frame.origin.y),
                isPrimary: display.frame.origin == .zero
            )
        }
    }

    public func start(displayID: DisplayID, configuration: StreamConfiguration, capturesAudio: Bool) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID.rawValue }) else {
            throw ScreenCaptureError.displayNotFound(displayID)
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let streamConfiguration = makeStreamConfiguration(configuration, capturesAudio: capturesAudio)

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesAudio, audioOutput != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    public func update(configuration: StreamConfiguration, capturesAudio: Bool = false) async throws {
        guard let stream else { return }
        try await stream.updateConfiguration(makeStreamConfiguration(configuration, capturesAudio: capturesAudio))
    }

    public func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            videoOutput(imageBuffer, sampleBuffer.presentationTimeStamp)
        case .audio:
            audioOutput?(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NuboLog.video.error("Screen capture stopped: \(error.localizedDescription, privacy: .public)")
    }

    private func makeStreamConfiguration(_ configuration: StreamConfiguration, capturesAudio: Bool) -> SCStreamConfiguration {
        let result = SCStreamConfiguration()
        result.width = configuration.width
        result.height = configuration.height
        result.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        result.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        result.queueDepth = 2
        result.showsCursor = true
        result.capturesAudio = capturesAudio
        result.sampleRate = 48_000
        result.channelCount = 2
        result.excludesCurrentProcessAudio = true
        result.captureResolution = .best
        return result
    }
}
#endif
