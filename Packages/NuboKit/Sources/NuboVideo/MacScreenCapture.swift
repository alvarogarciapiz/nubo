#if os(macOS)
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import NuboCore
@preconcurrency import ScreenCaptureKit

public enum ScreenCaptureError: LocalizedError {
    case displayNotFound(DisplayID)
    public var errorDescription: String? { "The selected Mac display is not currently available. Wake the Mac and check its displays." }
}

public final class MacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias VideoOutput = @Sendable (CVPixelBuffer, CMTime) -> Void
    public typealias AudioOutput = @Sendable (CMSampleBuffer) -> Void

    private let queue = DispatchQueue(label: "com.lvrpiz.nubo.capture", qos: .userInteractive)
    private let videoOutput: VideoOutput
    private let audioOutput: AudioOutput?
    private var stream: SCStream?
    private var streamConfiguration: SCStreamConfiguration?
    private var showsCursor = true

    public init(videoOutput: @escaping VideoOutput, audioOutput: AudioOutput? = nil) {
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
    }

    public func availableDisplays() async throws -> [DisplayDescriptor] {
        let content = try await SCShareableContent.current
        let displayNames: [CGDirectDisplayID: String] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        })
        return content.displays.map { display in
            let bounds = CGDisplayBounds(display.displayID)
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelWidth = mode?.pixelWidth ?? display.width
            let pixelHeight = mode?.pixelHeight ?? display.height
            let scale = bounds.width > 0 ? Double(pixelWidth) / bounds.width : 1
            return DisplayDescriptor(
                id: DisplayID(rawValue: display.displayID),
                name: displayNames[display.displayID] ?? "Display \(display.displayID)",
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale,
                originX: Double(bounds.origin.x),
                originY: Double(bounds.origin.y),
                isPrimary: display.displayID == CGMainDisplayID()
            )
        }
    }

    @MainActor
    public func previewJPEG() async throws -> Data? {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = max(2, Int(480 * Double(display.height) / Double(max(1, display.width))))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.55])
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
        self.streamConfiguration = streamConfiguration
        try await stream.startCapture()
    }

    public func update(configuration: StreamConfiguration, capturesAudio: Bool = false) async throws {
        guard let stream else { return }
        let updated = makeStreamConfiguration(configuration, capturesAudio: capturesAudio)
        try await stream.updateConfiguration(updated)
        streamConfiguration = updated
    }

    public func setShowsCursor(_ visible: Bool) async throws {
        guard showsCursor != visible, let stream, let streamConfiguration else { return }
        showsCursor = visible
        streamConfiguration.showsCursor = visible
        try await stream.updateConfiguration(streamConfiguration)
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
        result.showsCursor = showsCursor
        result.capturesAudio = capturesAudio
        result.sampleRate = 48_000
        result.channelCount = 2
        result.excludesCurrentProcessAudio = true
        result.captureResolution = .best
        return result
    }
}
#endif
