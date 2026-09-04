import AppKit
@preconcurrency import ApplicationServices
import Foundation
import CoreMedia
import NuboCore
import NuboInput
import NuboNetworking
import NuboProtocol
import NuboVideo
import Observation
import ServiceManagement

enum PermissionKind: CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case localNetwork

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .localNetwork: "Local Network"
        }
    }

    var explanation: String {
        switch self {
        case .screenRecording: "Required to stream your Mac display."
        case .accessibility: "Required to send keyboard and pointer input."
        case .localNetwork: "Required to be discovered by your iPad."
        }
    }
}

@MainActor
@Observable
final class MacAppModel {
    var screenRecordingGranted = false
    var accessibilityGranted = false
    var localNetworkAcknowledged = false
    var connectedDeviceName: String?
    var sessionStartedAt: Date?
    var errorMessage: String?

    @ObservationIgnored private let server: NuboHostServer
    @ObservationIgnored private let inputInjector = MacEventInjector()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var capture: MacScreenCapture?
    @ObservationIgnored private var encoder: LowLatencyH264Encoder?
    @ObservationIgnored private var videoSender: LatestVideoSender?
    @ObservationIgnored private var activePeerID: UUID?
    @ObservationIgnored private let adaptiveStreaming = AdaptiveStreamingController()
    @ObservationIgnored private let clipboardGuard = ClipboardLoopGuard()
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?

    var didFinishOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "didFinishMacOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "didFinishMacOnboarding") }
    }

    init() {
        let identity = Self.loadIdentity()
        server = NuboHostServer(identity: identity)
        refreshPermissions()
        observeServer()
        if didFinishOnboarding { startServer() }
    }

    var isReady: Bool {
        screenRecordingGranted && accessibilityGranted && localNetworkAcknowledged
    }

    var startAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func request(_ permission: PermissionKind) {
        switch permission {
        case .screenRecording:
            screenRecordingGranted = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        case .localNetwork:
            startServer()
        }
    }

    func finishOnboarding() {
        guard isReady else { return }
        didFinishOnboarding = true
        startServer()
        NSApp.setActivationPolicy(.accessory)
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startServer() {
        Task {
            do { try await server.start() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func observeServer() {
        eventTask = Task { [weak self, server] in
            for await event in await server.events() {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: HostEvent) async {
        switch event {
        case .listening:
            localNetworkAcknowledged = true
        case let .pairingRequested(requestID, peerName, code):
            let alert = NSAlert()
            alert.messageText = "Allow \(peerName) to control this Mac?"
            alert.informativeText = "Confirm that this code also appears on your iPad:\n\n\(code)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            NSApp.activate(ignoringOtherApps: true)
            let accepted = alert.runModal() == .alertFirstButtonReturn
            await server.decidePairing(requestID: requestID, accepted: accepted)
        case let .authenticated(peerID, peerName, channel):
            if channel == .control {
                activePeerID = peerID
                connectedDeviceName = peerName
                sessionStartedAt = .now
                startClipboardMonitoring(peerID: peerID)
                NuboLog.networking.info("Authenticated peer \(peerID.uuidString, privacy: .private)")
            } else if channel == .video {
                await startVideo(to: peerID)
            }
        case let .message(peerID, message):
            await handle(message, from: peerID)
        case .disconnected:
            connectedDeviceName = nil
            sessionStartedAt = nil
            activePeerID = nil
            clipboardTask?.cancel()
            await stopVideo()
        case let .failed(reason):
            errorMessage = reason
        }
    }

    private func startVideo(to peerID: UUID, selectedDisplayID: DisplayID? = nil) async {
        guard screenRecordingGranted else { return }
        await stopVideo()
        do {
            let configuration = StreamConfiguration.lanDefault
            let server = self.server
            let sender = LatestVideoSender(server: server, peerID: peerID, configuration: configuration)
            let encoder = try LowLatencyH264Encoder(configuration: configuration) { packet in
                Task {
                    await sender.submit(packet)
                }
            }
            let capture = MacScreenCapture { pixelBuffer, presentationTime in
                try? encoder.encode(pixelBuffer, presentationTime: presentationTime)
            }
            let displays = try await capture.availableDisplays()
            guard let display = selectedDisplayID.flatMap({ id in displays.first(where: { $0.id == id }) })
                    ?? displays.first(where: \.isPrimary)
                    ?? displays.first else {
                throw ScreenCaptureError.displayNotFound(.init(rawValue: 0))
            }
            await sender.setDisplayID(display.id)
            self.videoSender = sender
            self.encoder = encoder
            self.capture = capture
            try await capture.start(displayID: display.id, configuration: configuration, capturesAudio: false)
            try await server.send(.displays(displays), to: peerID, channel: .control)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopVideo() async {
        await videoSender?.cancel()
        videoSender = nil
        try? await capture?.stop()
        capture = nil
        encoder?.invalidate()
        encoder = nil
    }

    private func handle(_ message: NuboMessage, from peerID: UUID) async {
        switch message {
        case let .pointer(event):
            await inputInjector.inject(event)
        case let .key(event):
            await inputInjector.inject(event)
        case let .ping(value):
            try? await server.send(.pong(value), to: peerID, channel: .control)
        case let .selectDisplay(displayID):
            await startVideo(to: peerID, selectedDisplayID: displayID)
        case let .networkStats(metrics):
            if let configuration = await adaptiveStreaming.ingest(metrics) {
                do {
                    await videoSender?.update(configuration: configuration)
                    try encoder?.update(configuration: configuration)
                    try await capture?.update(configuration: configuration)
                } catch {
                    NuboLog.video.error("Stream adaptation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        case let .clipboardText(_, text):
            await clipboardGuard.markRemoteText(text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
    }

    private func startClipboardMonitoring(peerID: UUID) {
        clipboardTask?.cancel()
        clipboardTask = Task { [weak self] in
            var lastChangeCount = NSPasteboard.general.changeCount
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount != lastChangeCount else { continue }
                lastChangeCount = pasteboard.changeCount
                guard let text = pasteboard.string(forType: .string), await clipboardGuard.shouldSendLocalText(text) else { continue }
                try? await server.send(.clipboardText(id: UUID(), text: text), to: peerID, channel: .control)
            }
        }
    }

    private static func loadIdentity() -> LocalIdentity {
        let key = "nuboMacDeviceID"
        let defaults = UserDefaults.standard
        let id: UUID
        if let stored = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            id = stored
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: key)
        }
        return LocalIdentity(id: id, name: Host.current().localizedName ?? "Mac")
    }
}

private actor LatestVideoSender {
    private let server: NuboHostServer
    private let peerID: UUID
    private var configuration: StreamConfiguration
    private var displayID = DisplayID(rawValue: 0)
    private var sequence: UInt64 = 0
    private var pendingPacket: VideoPacket?
    private var isDraining = false
    private var isActive = true

    init(server: NuboHostServer, peerID: UUID, configuration: StreamConfiguration) {
        self.server = server
        self.peerID = peerID
        self.configuration = configuration
    }

    func setDisplayID(_ displayID: DisplayID) {
        self.displayID = displayID
    }

    func update(configuration: StreamConfiguration) {
        self.configuration = configuration
    }

    /// One-slot encoded-frame queue. If the network cannot keep up, stale P-frames
    /// are replaced instead of accumulating latency. A pending keyframe is retained
    /// until sent because subsequent frames may depend on it.
    func submit(_ packet: VideoPacket) {
        guard isActive else { return }
        if pendingPacket?.isKeyFrame != true || packet.isKeyFrame {
            pendingPacket = packet
        }
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    func cancel() {
        isActive = false
        pendingPacket = nil
    }

    private func drain() async {
        while isActive, let packet = pendingPacket {
            pendingPacket = nil
            do {
                if !packet.parameterSets.isEmpty {
                    try await server.send(
                        .videoConfiguration(.init(
                            codec: "h264",
                            width: configuration.width,
                            height: configuration.height,
                            parameterSets: packet.parameterSets
                        )),
                        to: peerID,
                        channel: .video
                    )
                }
                guard isActive else { break }
                let time = CMTimeConvertScale(
                    packet.presentationTime,
                    timescale: 1_000_000_000,
                    method: .default
                ).value
                try await server.send(
                    .videoFrame(.init(
                        sequence: sequence,
                        presentationTimeNanoseconds: UInt64(max(0, time)),
                        displayID: displayID,
                        isKeyFrame: packet.isKeyFrame,
                        bytes: packet.data
                    )),
                    to: peerID,
                    channel: .video
                )
                sequence &+= 1
            } catch {
                NuboLog.networking.error("Video send failed: \(error.localizedDescription, privacy: .public)")
                isActive = false
                pendingPacket = nil
            }
        }
        isDraining = false
    }
}
