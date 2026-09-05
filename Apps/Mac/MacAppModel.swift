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

enum PermissionKind: CaseIterable, Hashable, Identifiable {
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
    var requestedPermissions: Set<PermissionKind> = []
    var permissionStatusMessage: String?
    var screenRecordingMayNeedRelaunch = false
    var showsReadyConfirmation = false

    @ObservationIgnored private let server: NuboHostServer
    @ObservationIgnored private let inputInjector = MacEventInjector()
    @ObservationIgnored private let pairingPresenter = MacPairingPresenter()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var capture: MacScreenCapture?
    @ObservationIgnored private var encoder: LowLatencyH264Encoder?
    @ObservationIgnored private var videoSender: LatestVideoSender?
    @ObservationIgnored private var activePeerID: UUID?
    @ObservationIgnored private let adaptiveStreaming = AdaptiveStreamingController()
    @ObservationIgnored private let clipboardGuard = ClipboardLoopGuard()
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?
    @ObservationIgnored private var serverRestartTask: Task<Void, Never>?
    @ObservationIgnored private var requestedStreamConfiguration = StreamConfiguration.lanDefault
    @ObservationIgnored private var activeDisplay: DisplayDescriptor?
    @ObservationIgnored private var preferredCodec: VideoCodec = .h264
    @ObservationIgnored private let desktopResolution = DesktopResolutionController()
    @ObservationIgnored private var lastPreviewAt: [UUID: Date] = [:]
    @ObservationIgnored private var readyConfirmationTask: Task<Void, Never>?

    var didFinishOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "didFinishMacOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "didFinishMacOnboarding") }
    }

    init() {
        let identity = Self.loadIdentity()
        server = NuboHostServer(identity: identity)
        observeServer()
        refreshPermissions()
        if didFinishOnboarding { startServer() }
    }

    var isReady: Bool {
        screenRecordingGranted && accessibilityGranted && localNetworkAcknowledged
    }

    var shouldPresentOnboardingAtLaunch: Bool {
        !didFinishOnboarding || !screenRecordingGranted || !accessibilityGranted
    }

    var startAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func refreshPermissions() {
        let wasReady = isReady
        let hadScreenRecording = screenRecordingGranted
        let hadAccessibility = accessibilityGranted

        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()

        if screenRecordingGranted {
            screenRecordingMayNeedRelaunch = false
        }
        if screenRecordingGranted && accessibilityGranted && !localNetworkAcknowledged {
            startServer()
        }

        if !wasReady, isReady {
            completeSetupIfReady()
        } else if !hadScreenRecording, screenRecordingGranted {
            permissionStatusMessage = "Screen Recording enabled. Continuing to Accessibility."
        } else if !hadAccessibility, accessibilityGranted {
            permissionStatusMessage = "Accessibility enabled. Checking the local service."
        }
    }

    func verifyPermissionsAfterReturning() async {
        refreshPermissions()
        guard !screenRecordingGranted, requestedPermissions.contains(.screenRecording) else { return }
        await verifyScreenRecordingWithScreenCaptureKit()
    }

    func request(_ permission: PermissionKind) {
        requestedPermissions.insert(permission)
        errorMessage = nil
        switch permission {
        case .screenRecording:
            screenRecordingGranted = CGRequestScreenCaptureAccess()
            screenRecordingMayNeedRelaunch = !screenRecordingGranted
            permissionStatusMessage = screenRecordingGranted
                ? "Screen Recording enabled."
                : "Enable Nubo in System Settings. If macOS quits Nubo, reopen it and setup will continue automatically."
            Task { [weak self] in
                await self?.verifyScreenRecordingWithScreenCaptureKit()
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            accessibilityGranted = AXIsProcessTrustedWithOptions(options)
            permissionStatusMessage = accessibilityGranted
                ? "Accessibility enabled."
                : "Enable Nubo in System Settings, then return here. This screen checks automatically."
        case .localNetwork:
            permissionStatusMessage = "Starting Nubo's private local service…"
            startServer()
        }
    }

    private func verifyScreenRecordingWithScreenCaptureKit() async {
        do {
            let probe = MacScreenCapture { _, _ in }
            _ = try await probe.availableDisplays()
            let wasReady = isReady
            screenRecordingGranted = true
            screenRecordingMayNeedRelaunch = false
            if !wasReady, isReady {
                completeSetupIfReady()
            } else {
                permissionStatusMessage = "Screen Recording enabled for this copy of Nubo."
            }
            if accessibilityGranted && !localNetworkAcknowledged {
                startServer()
            }
        } catch {
            screenRecordingGranted = false
            screenRecordingMayNeedRelaunch = true
            permissionStatusMessage = "This signed copy of Nubo is not authorized yet. Click Request Again, then enable Nubo in the list."
        }
    }

    func openSystemSettings(for permission: PermissionKind) {
        let location: String
        switch permission {
        case .screenRecording:
            location = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            location = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .localNetwork:
            location = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        }
        guard let url = URL(string: location) else { return }
        permissionStatusMessage = "Nubo will check again as soon as you return from System Settings."
        NSWorkspace.shared.open(url)
    }

    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        permissionStatusMessage = "Finder is showing the exact copy of Nubo that macOS needs to authorize."
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
            catch {
                errorMessage = error.localizedDescription
                scheduleServerRestart()
            }
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
            serverRestartTask?.cancel()
            serverRestartTask = nil
            localNetworkAcknowledged = true
            errorMessage = nil
            if isReady {
                completeSetupIfReady()
            } else {
                permissionStatusMessage = "Local service is ready."
            }
        case let .pairingRequested(requestID, peerName, code):
            pairingPresenter.present(peerName: peerName, code: code) { [server] accepted in
                Task { await server.decidePairing(requestID: requestID, accepted: accepted) }
            }
        case let .authenticated(peerID, peerName, channel):
            if channel == .control {
                activePeerID = peerID
                requestedStreamConfiguration = .lanDefault
                preferredCodec = .h264
                connectedDeviceName = peerName
                sessionStartedAt = .now
                startClipboardMonitoring(peerID: peerID)
                NuboLog.networking.info("Authenticated peer \(peerID.uuidString, privacy: .private)")
            } else if channel == .video {
                await startVideo(to: peerID)
            }
        case let .message(peerID, message):
            await handle(message, from: peerID)
        case let .disconnected(peerID, _):
            guard activePeerID == peerID else { return }
            connectedDeviceName = nil
            sessionStartedAt = nil
            activePeerID = nil
            clipboardTask?.cancel()
            await inputInjector.releaseAll()
            await stopVideo()
            desktopResolution.restore()
        case let .failed(reason):
            localNetworkAcknowledged = false
            showsReadyConfirmation = false
            errorMessage = reason
            permissionStatusMessage = "The local service stopped. Nubo is trying to restore it automatically."
            scheduleServerRestart()
        }
    }

    private func scheduleServerRestart() {
        guard serverRestartTask == nil else { return }
        serverRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.serverRestartTask = nil
            self.startServer()
        }
    }

    private func completeSetupIfReady() {
        guard isReady else { return }
        permissionStatusMessage = "All permissions are enabled. Nubo is running in the menu bar."
        didFinishOnboarding = true
        showsReadyConfirmation = true
        NSApp.setActivationPolicy(.accessory)
        readyConfirmationTask?.cancel()
        readyConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.showsReadyConfirmation = false
        }
    }

    private func startVideo(to peerID: UUID, selectedDisplayID: DisplayID? = nil) async {
        await stopVideo()
        do {
            let displayProbe = MacScreenCapture { _, _ in }
            let displays = try await displayProbe.availableDisplays()
            screenRecordingGranted = true
            try await server.send(.displays(displays), to: peerID, channel: .control)
            guard let display = selectedDisplayID.flatMap({ id in displays.first(where: { $0.id == id }) })
                    ?? displays.first(where: \.isPrimary)
                    ?? displays.first else {
                throw ScreenCaptureError.displayNotFound(.init(rawValue: 0))
            }
            let configuration = fitted(requestedStreamConfiguration, to: display)
            await adaptiveStreaming.replaceConfiguration(configuration)
            let server = self.server
            let sender = LatestVideoSender(server: server, peerID: peerID, configuration: configuration)
            let output: LowLatencyH264Encoder.Output = { packet in
                Task {
                    await sender.submit(packet)
                }
            }
            let encoder: LowLatencyH264Encoder
            do { encoder = try LowLatencyH264Encoder(configuration: configuration, codec: preferredCodec, output: output) }
            catch where preferredCodec == .hevc {
                NuboLog.video.notice("HEVC unavailable; using H.264")
                encoder = try LowLatencyH264Encoder(configuration: configuration, codec: .h264, output: output)
            }
            await sender.setCodec(encoder.codec)
            let capture = MacScreenCapture { pixelBuffer, presentationTime in
                try? encoder.encode(pixelBuffer, presentationTime: presentationTime)
            }
            await sender.setDisplayID(display.id)
            activeDisplay = display
            self.videoSender = sender
            self.encoder = encoder
            self.capture = capture
            try await capture.start(displayID: display.id, configuration: configuration, capturesAudio: false)
        } catch {
            errorMessage = error.localizedDescription
            NuboLog.video.error("Cannot start desktop stream: \(error.localizedDescription, privacy: .public)")
            await stopVideo()
            try? await server.send(.disconnect(reason: "Mac could not start screen sharing: \(error.localizedDescription). Check Screen Recording permission on the Mac."), to: peerID, channel: .control)
        }
    }

    private func stopVideo() async {
        await videoSender?.cancel()
        videoSender = nil
        try? await capture?.stop()
        capture = nil
        encoder?.invalidate()
        encoder = nil
        activeDisplay = nil
    }

    private func handle(_ message: NuboMessage, from peerID: UUID) async {
        switch message {
        case .previewRequest:
            let now = Date()
            guard now.timeIntervalSince(lastPreviewAt[peerID] ?? .distantPast) >= 8 else { break }
            lastPreviewAt[peerID] = now
            // Paired read-only channel. Never starts control, input or a video encoder.
            let jpeg: Data?
            if activePeerID == nil, CGPreflightScreenCaptureAccess() {
                jpeg = try? await MacScreenCapture { _, _ in }.previewJPEG()
            } else { jpeg = nil }
            try? await server.send(.previewImage(jpeg: jpeg ?? Data(), capturedAt: now), to: peerID, channel: .preview)
        case let .pointer(event):
            switch event {
            case .absoluteMotion: try? await capture?.setShowsCursor(false)
            case .relativeMotion: try? await capture?.setShowsCursor(true)
            default: break
            }
            await inputInjector.inject(event)
        case let .key(event):
            await inputInjector.inject(event)
        case let .ping(value):
            try? await server.send(.pong(value), to: peerID, channel: .control)
        case let .selectDisplay(displayID):
            await startVideo(to: peerID, selectedDisplayID: displayID)
        case .requestKeyFrame:
            encoder?.requestKeyFrame()
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
        case let .streamConfiguration(configuration):
            requestedStreamConfiguration = sanitized(configuration)
            let appliedConfiguration = activeDisplay.map { fitted(requestedStreamConfiguration, to: $0) }
                ?? requestedStreamConfiguration
            await adaptiveStreaming.replaceConfiguration(appliedConfiguration)
            do {
                await videoSender?.update(configuration: appliedConfiguration)
                try encoder?.update(configuration: appliedConfiguration)
                try await capture?.update(configuration: appliedConfiguration)
            } catch {
                NuboLog.video.error("Client stream configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        case let .preferredVideoCodec(codec):
            guard preferredCodec != codec else { break }
            preferredCodec = codec
            if let display = activeDisplay { await startVideo(to: peerID, selectedDisplayID: display.id) }
        case let .desktopViewport(width, height, enabled):
            guard let display = activeDisplay else { break }
            await stopVideo()
            let status: String
            if enabled {
                status = desktopResolution.fit(displayID: display.id.rawValue, width: width, height: height)
            } else {
                desktopResolution.restore()
                status = "Original Mac desktop resolution restored."
            }
            await startVideo(to: peerID, selectedDisplayID: display.id)
            try? await server.send(.desktopViewportStatus(status), to: peerID, channel: .control)
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

    private func sanitized(_ configuration: StreamConfiguration) -> StreamConfiguration {
        StreamConfiguration(
            width: min(max(configuration.width, 960), 3_840),
            height: min(max(configuration.height, 600), 3_840),
            framesPerSecond: min(max(configuration.framesPerSecond, 24), 60),
            bitrate: min(max(configuration.bitrate, 2_000_000), 45_000_000),
            keyFrameInterval: min(max(configuration.keyFrameInterval, 30), 300)
        )
    }

    private func fitted(_ configuration: StreamConfiguration, to display: DisplayDescriptor) -> StreamConfiguration {
        guard display.pixelWidth > 0, display.pixelHeight > 0 else { return configuration }
        let scale = min(
            Double(configuration.width) / Double(display.pixelWidth),
            Double(configuration.height) / Double(display.pixelHeight),
            1
        )
        let width = max(2, Int((Double(display.pixelWidth) * scale).rounded(.down)) & ~1)
        let height = max(2, Int((Double(display.pixelHeight) * scale).rounded(.down)) & ~1)
        return .init(
            width: width,
            height: height,
            framesPerSecond: configuration.framesPerSecond,
            bitrate: configuration.bitrate,
            keyFrameInterval: configuration.keyFrameInterval
        )
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
    private var codec: VideoCodec = .h264
    func setCodec(_ codec: VideoCodec) { self.codec = codec }
    private let server: NuboHostServer
    private let peerID: UUID
    private var configuration: StreamConfiguration
    private var displayID = DisplayID(rawValue: 0)
    private var sequence: UInt64 = 0
    private var pendingPacket: (packet: VideoPacket, sequence: UInt64)?
    private var isDraining = false
    private var isActive = true
    private var presentationTimeOrigin: CMTime?

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
        let packetSequence = sequence
        sequence &+= 1
        if pendingPacket?.packet.isKeyFrame != true || packet.isKeyFrame {
            pendingPacket = (packet, packetSequence)
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
        while isActive, let pending = pendingPacket {
            pendingPacket = nil
            let packet = pending.packet
            do {
                if !packet.parameterSets.isEmpty {
                    try await server.send(
                        .videoConfiguration(.init(
                            codec: codec.rawValue,
                            width: configuration.width,
                            height: configuration.height,
                            parameterSets: packet.parameterSets
                        )),
                        to: peerID,
                        channel: .video
                    )
                }
                guard isActive else { break }
                let origin = presentationTimeOrigin ?? packet.presentationTime
                presentationTimeOrigin = origin
                let relativeTime = CMTimeSubtract(packet.presentationTime, origin)
                let time = CMTimeConvertScale(
                    relativeTime,
                    timescale: 1_000_000_000,
                    method: .default
                ).value
                try await server.send(
                    .videoFrame(.init(
                        sequence: pending.sequence,
                        presentationTimeNanoseconds: UInt64(max(0, time)),
                        displayID: displayID,
                        isKeyFrame: packet.isKeyFrame,
                        bytes: packet.data
                    )),
                    to: peerID,
                    channel: .video
                )
            } catch {
                NuboLog.networking.error("Video send failed: \(error.localizedDescription, privacy: .public)")
                isActive = false
                pendingPacket = nil
            }
        }
        isDraining = false
    }
}
