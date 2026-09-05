import Foundation
import NuboCore
import NuboNetworking
import NuboProtocol
import NuboVideo
import CoreMedia
import Observation
import SwiftUI

@MainActor
@Observable
final class iPadAppModel {
    var hosts: [DiscoveredHost] = []
    var previews: [String: UIImage] = [:]
    var previewDates: [String: Date] = [:]
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewConnection: EncryptedMessageConnection?
    @ObservationIgnored private var previewGeneration = UUID()

    func startPreviews() {
        stopPreviews()
        let generation = previewGeneration
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for host in self.hosts.prefix(12) {
                    guard !Task.isCancelled, self.connectionState == .idle else { return }
                    let peerID = host.peerID ?? UserDefaults.standard.string(forKey: self.manualPeerKey(host.endpoint)).flatMap(UUID.init(uuidString:))
                    guard let peerID, let credential = try? await self.sessionClient.savedCredential(for: peerID) else { continue }
                    var request: EncryptedMessageConnection?
                    do {
                        let connection = try await self.sessionClient.resume(endpoint: host.endpoint, identity: self.identity, credential: credential, channel: .preview)
                        request = connection
                        guard !Task.isCancelled else { await connection.cancel(); return }
                        self.previewConnection = connection
                        let timeout = Task {
                            try? await Task.sleep(for: .seconds(5))
                            if !Task.isCancelled { await connection.cancel() }
                        }
                        defer { timeout.cancel() }
                        try await connection.send(.previewRequest)
                        let message = try await connection.receive()
                        await connection.cancel()
                        if self.previewGeneration == generation { self.previewConnection = nil }
                        if case let .previewImage(jpeg, date) = message, !Task.isCancelled,
                           jpeg.count <= 300_000, let image = UIImage(data: jpeg),
                           image.size.width <= 1024, image.size.height <= 1024 {
                            self.previews[host.id] = image
                            self.previewDates[host.id] = date
                        }
                    } catch {
                        await request?.cancel()
                        if self.previewGeneration == generation { self.previewConnection = nil }
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopPreviews() {
        previewGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
        let connection = previewConnection
        previewConnection = nil
        Task { await connection?.cancel() }
    }
    var path: [ConnectionEndpoint] = []
    var connectionState: ConnectionState = .idle
    var selectedHostName = ""
    var showManualConnection = false
    var showSettings = false
    var pairingPeerName = ""
    var pairingCode = ""
    var showPairingConfirmation = false
    var displays: [DisplayDescriptor] = []
    var hasReceivedVideo = false
    @ObservationIgnored private var firstFrameTask: Task<Void, Never>?
    var metrics = ConnectionMetrics()
    var activeDisplayID: DisplayID?
    var videoWidth = 0
    var videoHeight = 0
    var videoCodec: VideoCodec = .h264
    var desktopViewportStatus = ""
    @ObservationIgnored private var requestedH264Fallback = false
    var pairingError: String?
    private var pairingFailures = 0
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private var viewportPixels = CGSize(width: 2732, height: 2048)
    @ObservationIgnored private var viewportPoints = CGSize(width: 1366, height: 1024)
    @ObservationIgnored private var lastDesktopViewport: String?

    func applyDesktopViewport() {
        guard connectionState == .connected, !displays.isEmpty else { return }
        let enabled = UserDefaults.standard.bool(forKey: "matchDesktopViewport")
        let key = "\(Int(viewportPoints.width))x\(Int(viewportPoints.height)):\(enabled):\(activeDisplayID?.rawValue ?? 0)"
        guard key != lastDesktopViewport else { return }
        lastDesktopViewport = key
        if enabled || !desktopViewportStatus.isEmpty {
            send(.desktopViewport(width: Int(viewportPoints.width), height: Int(viewportPoints.height), enabled: enabled))
        }
    }
    @ObservationIgnored private var viewportTask: Task<Void, Never>?

    var selectedDisplay: DisplayDescriptor? {
        displays.first { $0.id == activeDisplayID } ?? displays.first(where: \.isPrimary) ?? displays.first
    }

    @ObservationIgnored
    private let discovery: any DiscoveryService
    @ObservationIgnored
    private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private let sessionClient: SecureSessionClient
    @ObservationIgnored private var session: ClientSecureSession?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var videoReceiveTask: Task<Void, Never>?
    @ObservationIgnored private var videoConnection: EncryptedMessageConnection?
    @ObservationIgnored private var inputConnection: EncryptedMessageConnection?
    @ObservationIgnored private var inputSendTask: Task<Void, Never>?
    @ObservationIgnored private var inputQueue: [NuboMessage] = []
    @ObservationIgnored private var pairingContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored let frameMailbox: LatestFrameMailbox
    @ObservationIgnored private let decoder: LowLatencyH264Decoder
    @ObservationIgnored private var videoParameterSets: [Data] = []
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var receivedVideoBytes = 0
    @ObservationIgnored private var receivedFrames = 0
    @ObservationIgnored private var droppedFrames = 0
    @ObservationIgnored private var lastVideoSequence: UInt64?
    @ObservationIgnored private var lastVideoArrival: UInt64?
    @ObservationIgnored private var lastVideoPresentation: UInt64?
    @ObservationIgnored private var lastKeyFrameRequest: UInt64?
    @ObservationIgnored private var consecutiveVideoFailures = 0
    @ObservationIgnored private let clipboardGuard = ClipboardLoopGuard()
    @ObservationIgnored private var activeEndpoint: ConnectionEndpoint?
    @ObservationIgnored private var activePeerID: UUID?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var transportToken: UUID?
    @ObservationIgnored private var nextPingID: UInt64 = 0
    @ObservationIgnored private var pendingPings: [UInt64: UInt64] = [:]

    init(discovery: any DiscoveryService = BonjourDiscoveryService(), sessionClient: SecureSessionClient = SecureSessionClient()) {
        self.discovery = discovery
        self.sessionClient = sessionClient
        self.identity = Self.loadIdentity()
        let mailbox = LatestFrameMailbox()
        self.frameMailbox = mailbox
        self.decoder = LowLatencyH264Decoder { pixelBuffer, _ in mailbox.submit(pixelBuffer) }
        startDiscovery()
    }

    func startDiscovery() {
        discovery.start()
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self, discovery] in
            for await hosts in discovery.hosts() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let hidden = Set(UserDefaults.standard.stringArray(forKey: "nubo.hiddenHosts") ?? [])
                self.hosts = hosts.filter { !hidden.contains($0.peerID?.uuidString ?? $0.id) }
            }
        }
    }

    func connect(to host: DiscoveredHost) {
        prepareForNewConnection()
        selectedHostName = host.name
        path.append(host.endpoint)
        connectionState = .connecting
        let savedID = UserDefaults.standard.string(forKey: manualPeerKey(host.endpoint)).flatMap(UUID.init(uuidString:))
        beginConnection(endpoint: host.endpoint, expectedPeerID: host.peerID ?? savedID)
    }

    func forget(_ host: DiscoveredHost) async throws {
        stopPreviews()
        let defaults = UserDefaults.standard
        let peerID = host.peerID ?? defaults.string(forKey: manualPeerKey(host.endpoint)).flatMap(UUID.init(uuidString:))
        if let peerID {
            try await sessionClient.forget(peerID: peerID)
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("nubo.manualPeer.") && value as? String == peerID.uuidString {
                defaults.removeObject(forKey: key)
            }
        }
        var hidden = Set(defaults.stringArray(forKey: "nubo.hiddenHosts") ?? [])
        hidden.insert(host.peerID?.uuidString ?? host.id)
        defaults.set(Array(hidden), forKey: "nubo.hiddenHosts")
        hosts.removeAll { $0.id == host.id }
        previews.removeValue(forKey: host.id)
        previewDates.removeValue(forKey: host.id)
        startPreviews()
    }

    func showNearbyMacs() {
        UserDefaults.standard.removeObject(forKey: "nubo.hiddenHosts")
        startDiscovery()
    }

    func connectManually(host: String, port: Int) throws {
        let endpoint = try ManualEndpoint(host: host, port: port)
        prepareForNewConnection()
        selectedHostName = endpoint.host
        path.append(endpoint.endpoint)
        connectionState = .connecting
        showManualConnection = false
        let savedID = UserDefaults.standard.string(forKey: manualPeerKey(endpoint.endpoint)).flatMap(UUID.init(uuidString:))
        beginConnection(endpoint: endpoint.endpoint, expectedPeerID: savedID)
    }

    func disconnect() {
        activeEndpoint = nil
        activePeerID = nil
        cancelPendingPairing()
        reconnectTask?.cancel()
        connectionTask?.cancel()
        cancelTransport()
        path.removeAll()
        connectionState = .idle
    }

    func retryConnection() {
        guard let endpoint = activeEndpoint else {
            connectionState = .unavailable(reason: "The connection endpoint is no longer available.")
            return
        }
        let peerID = activePeerID
        cancelPendingPairing()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTask?.cancel()
        cancelTransport()
        reconnectAttempt = 0
        connectionState = .connecting
        beginConnection(endpoint: endpoint, expectedPeerID: peerID)
    }

    func decidePairing(_ accepted: Bool) {
        pairingTimeout?.cancel()
        showPairingConfirmation = false
        pairingContinuation?.resume(returning: accepted)
        pairingContinuation = nil
    }

    func submitPairingCode(_ code: String) {
        guard showPairingConfirmation else { return }
        if PairingCode.matches(code, expected: pairingCode) {
            decidePairing(true)
        } else {
            pairingFailures += 1
            pairingError = "That code doesn’t match. Check the code on your Mac."
            if pairingFailures >= 3 { decidePairing(false) }
        }
    }

    func updateViewport(_ size: CGSize, scale: CGFloat) {
        viewportPoints = size
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width > 0, pixels.height > 0, pixels != viewportPixels else { return }
        viewportPixels = pixels
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            applyStreamingPreferences(quality: UserDefaults.standard.string(forKey: "streamingQuality") ?? "automatic", frameRate: UserDefaults.standard.string(forKey: "frameRate") ?? "automatic")
            applyDesktopViewport()
        }
    }

    func sendShortcut(hidUsage: UInt16, modifiers: KeyModifiers = .command) {
        send(.key(.init(hidUsage: hidUsage, characters: nil, isDown: true, isRepeat: false, modifiers: modifiers)))
        send(.key(.init(hidUsage: hidUsage, characters: nil, isDown: false, isRepeat: false, modifiers: [])))
    }

    private func manualPeerKey(_ endpoint: ConnectionEndpoint) -> String {
        "nubo.manualPeer.\(String(describing: endpoint))"
    }

    func send(_ message: NuboMessage) {
        if message.channel == .input {
            enqueueInput(message)
            return
        }
        guard let connection = session?.control else { return }
        guard let token = transportToken else { return }
        Task {
            do { try await connection.send(message) }
            catch { connectionFailed(error, token: token) }
        }
    }

    func sendClipboard() {
        guard UserDefaults.standard.object(forKey: "clipboardSync") as? Bool ?? true,
              let text = UIPasteboard.general.string else { return }
        send(.clipboardText(id: UUID(), text: text))
    }

    func applyStreamingPreferences(quality: String, frameRate: String) {
        let size = quality == "native" ? CGSize(width: 3840, height: 3840) : viewportPixels
        let configuration = StreamingQuality.configuration(quality: quality, pixelWidth: Int(size.width), pixelHeight: Int(size.height), frameRate: frameRate)
        send(.streamConfiguration(configuration))
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startDiscovery()
            if case .reconnecting = connectionState, let endpoint = activeEndpoint {
                beginConnection(endpoint: endpoint, expectedPeerID: activePeerID, resetsBackoff: false)
            }
        case .background:
            stopPreviews()
            previews.removeAll()
            previewDates.removeAll()
            discovery.stop()
            discoveryTask?.cancel()
            if connectionState != .idle {
                cancelPendingPairing()
                connectionTask?.cancel()
                cancelTransport()
                connectionState = .reconnecting(attempt: reconnectAttempt)
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func beginConnection(endpoint: ConnectionEndpoint, expectedPeerID: UUID?, resetsBackoff: Bool = true) {
        let token = UUID()
        transportToken = token
        activeEndpoint = endpoint
        if let expectedPeerID { activePeerID = expectedPeerID }
        if resetsBackoff { reconnectAttempt = 0 }
        connectionTask?.cancel()
        connectionTask = Task { [weak self, sessionClient, identity] in
            guard let self else { return }
            do {
                let session = try await sessionClient.connect(
                    to: endpoint,
                    identity: identity,
                    expectedPeerID: expectedPeerID,
                    approvePairing: { [weak self] name, code in
                        guard let self else { return false }
                        return await self.requestPairingApproval(name: name, code: code)
                    }
                )
                guard !Task.isCancelled, self.transportToken == token else { await session.control.cancel(); return }
                self.session = session
                self.requestedH264Fallback = false
                try await session.control.send(.preferredVideoCodec(LowLatencyH264Decoder.supportsHEVC ? .hevc : .h264))
                self.activePeerID = session.peerID
                UserDefaults.standard.set(session.peerID.uuidString, forKey: self.manualPeerKey(endpoint))
                self.reconnectAttempt = 0
                self.reconnectTask = nil
                self.selectedHostName = session.peerName
                async let input = sessionClient.resume(endpoint: endpoint, identity: identity, credential: session.credential, channel: .input)
                async let video = sessionClient.resume(endpoint: endpoint, identity: identity, credential: session.credential, channel: .video)
                let (inputConnection, videoConnection) = try await (input, video)
                guard !Task.isCancelled, self.transportToken == token else {
                    await inputConnection.cancel()
                    await videoConnection.cancel()
                    await session.control.cancel()
                    return
                }
                self.inputConnection = inputConnection
                self.videoConnection = videoConnection
                self.startReceiveLoop(session.control, token: token)
                self.startMetrics()
                self.startVideoReceiveLoop(videoConnection, token: token)
                self.connectionState = .connected
                self.hasReceivedVideo = false
                self.firstFrameTask?.cancel()
                self.firstFrameTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled, self.transportToken == token, !self.hasReceivedVideo else { return }
                    self.cancelTransport()
                    self.connectionState = .unavailable(reason: "Connected to the Mac, but no desktop video arrived. Check Screen Recording permission and the error shown in Nubo’s Mac menu, then try again.")
                }
                self.applyStreamingPreferences(
                    quality: UserDefaults.standard.string(forKey: "streamingQuality") ?? "automatic",
                    frameRate: UserDefaults.standard.string(forKey: "frameRate") ?? "automatic"
                )
            } catch {
                self.connectionFailed(error, token: token)
            }
        }
    }

    private func requestPairingApproval(name: String, code: String) async -> Bool {
        pairingPeerName = name
        pairingCode = code
        pairingError = nil
        pairingFailures = 0
        connectionState = .pairing(code: code)
        showPairingConfirmation = true
        return await withCheckedContinuation {
            pairingContinuation = $0
            pairingTimeout?.cancel()
            pairingTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.decidePairing(false)
            }
        }
    }

    private func cancelPendingPairing() {
        pairingTimeout?.cancel()
        showPairingConfirmation = false
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
    }

    private func startReceiveLoop(_ connection: EncryptedMessageConnection, token: UUID) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    self?.handle(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(error, token: token)
            }
        }
    }

    private func startVideoReceiveLoop(_ connection: EncryptedMessageConnection, token: UUID) {
        videoReceiveTask?.cancel()
        videoReceiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    self?.handleVideo(message, token: token)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(error, token: token)
            }
        }
    }

    private func handleVideo(_ message: NuboMessage, token: UUID) {
        do {
            switch message {
            case let .videoConfiguration(configuration):
                guard let codec = VideoCodec(rawValue: configuration.codec) else { throw VideoEncoderError.property(-1, "Unsupported codec") }
                videoWidth = configuration.width
                videoHeight = configuration.height
                if configuration.parameterSets != videoParameterSets || codec != videoCodec {
                    do { try decoder.configure(parameterSets: configuration.parameterSets, codec: codec) }
                    catch where codec == .hevc && !requestedH264Fallback {
                        requestedH264Fallback = true
                        send(.preferredVideoCodec(.h264))
                        return
                    }
                    videoCodec = codec
                    lastVideoSequence = nil
                    videoParameterSets = configuration.parameterSets
                }
                consecutiveVideoFailures = 0
            case let .videoFrame(frame):
                hasReceivedVideo = true
                firstFrameTask?.cancel()
                if activeDisplayID != frame.displayID {
                    activeDisplayID = frame.displayID
                    applyDesktopViewport()
                }
                recordFrameArrival(frame)
                receivedVideoBytes += frame.bytes.count
                receivedFrames += 1
                try decoder.decode(VideoPacket(
                    data: frame.bytes,
                    presentationTime: CMTime(value: Int64(clamping: frame.presentationTimeNanoseconds), timescale: 1_000_000_000),
                    isKeyFrame: frame.isKeyFrame
                ))
                consecutiveVideoFailures = 0
            default:
                break
            }
        } catch {
            consecutiveVideoFailures += 1
            requestKeyFrame()
            if consecutiveVideoFailures >= 3 {
                connectionFailed(error, token: token)
            }
        }
    }

    private func handle(_ message: NuboMessage) {
        switch message {
        case let .pong(pingID):
            let now = DispatchTime.now().uptimeNanoseconds
            if let sentAt = pendingPings.removeValue(forKey: pingID), now >= sentAt {
                metrics.rttMilliseconds = Double(now - sentAt) / 1_000_000
            }
        case let .displays(displays):
            self.displays = displays
            applyDesktopViewport()
        case let .desktopViewportStatus(status):
            desktopViewportStatus = status
        case let .clipboardText(_, text):
            guard UserDefaults.standard.object(forKey: "clipboardSync") as? Bool ?? true else { return }
            Task { [clipboardGuard] in
                await clipboardGuard.markRemoteText(text)
                UIPasteboard.general.string = text
            }
        case let .disconnect(reason):
            // An explicit host rejection is not a transient Wi-Fi interruption.
            // Keep its actionable reason visible instead of retrying forever.
            reconnectTask?.cancel()
            cancelTransport()
            connectionState = .unavailable(reason: reason ?? "Mac disconnected")
        default:
            break
        }
    }

    private func startMetrics() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                metrics.bitrate = receivedVideoBytes * 8
                metrics.framesPerSecond = Double(receivedFrames)
                metrics.droppedFrames = droppedFrames
                let totalFrames = receivedFrames + droppedFrames
                metrics.packetLoss = totalFrames > 0 ? Double(droppedFrames) / Double(totalFrames) : 0
                receivedVideoBytes = 0
                receivedFrames = 0
                droppedFrames = 0
                let pingID = nextPingID
                nextPingID &+= 1
                pendingPings[pingID] = DispatchTime.now().uptimeNanoseconds
                if pendingPings.count > 4 {
                    pendingPings.removeValue(forKey: pendingPings.keys.min() ?? pingID)
                }
                send(.ping(pingID))
                send(.networkStats(metrics))
            }
        }
    }

    private func connectionFailed(_ error: any Error, token: UUID) {
        guard transportToken == token else { return }
        guard connectionTask?.isCancelled != true else { return }
        guard reconnectTask == nil else { return }
        cancelTransport()
        guard let endpoint = activeEndpoint, let peerID = activePeerID, reconnectAttempt < 5 else {
            connectionState = .unavailable(reason: error.localizedDescription)
            return
        }
        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        reconnectTask?.cancel()
        let delay = min(8, 1 << (reconnectAttempt - 1))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.beginConnection(endpoint: endpoint, expectedPeerID: peerID, resetsBackoff: false)
        }
    }

    private func prepareForNewConnection() {
        cancelPendingPairing()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTask?.cancel()
        cancelTransport()
        activeEndpoint = nil
        activePeerID = nil
        displays = []
        activeDisplayID = nil
        videoWidth = 0
        videoHeight = 0
        _ = frameMailbox.take()
    }

    private func enqueueInput(_ message: NuboMessage) {
        guard inputConnection != nil, let token = transportToken else { return }
        if case .pointer(.absoluteMotion) = message,
           let last = inputQueue.last, case .pointer(.absoluteMotion) = last {
            inputQueue[inputQueue.count - 1] = message
        } else if case let .pointer(.relativeMotion(next)) = message,
           let last = inputQueue.last,
           case let .pointer(.relativeMotion(previous)) = last {
            inputQueue[inputQueue.count - 1] = .pointer(.relativeMotion(.init(
                dx: previous.dx + next.dx,
                dy: previous.dy + next.dy
            )))
        } else if case let .pointer(.scroll(next, precise)) = message,
                  let last = inputQueue.last,
                  case let .pointer(.scroll(previous, previousPrecise)) = last,
                  precise == previousPrecise {
            inputQueue[inputQueue.count - 1] = .pointer(.scroll(.init(
                dx: previous.dx + next.dx,
                dy: previous.dy + next.dy
            ), isPrecise: precise))
        } else {
            inputQueue.append(message)
        }

        if inputQueue.count > 128,
           let staleMotion = inputQueue.firstIndex(where: { item in
               if case .pointer(.relativeMotion) = item { return true }
               if case .pointer(.absoluteMotion) = item { return true }
               return false
           }) {
            inputQueue.remove(at: staleMotion)
        }

        guard inputSendTask == nil else { return }
        inputSendTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let connection = self.inputConnection,
                  !self.inputQueue.isEmpty {
                let next = self.inputQueue.removeFirst()
                do {
                    try await connection.send(next)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.connectionFailed(error, token: token)
                    return
                }
            }
            self.inputSendTask = nil
        }
    }

    private func cancelTransport() {
        lastDesktopViewport = nil
        firstFrameTask?.cancel()
        firstFrameTask = nil
        hasReceivedVideo = false
        transportToken = nil
        receiveTask?.cancel()
        videoReceiveTask?.cancel()
        metricsTask?.cancel()
        inputSendTask?.cancel()
        receiveTask = nil
        videoReceiveTask = nil
        metricsTask = nil
        inputSendTask = nil
        inputQueue.removeAll(keepingCapacity: true)
        let control = session?.control
        let video = videoConnection
        let input = inputConnection
        session = nil
        videoConnection = nil
        inputConnection = nil
        decoder.invalidate()
        videoParameterSets = []
        receivedVideoBytes = 0
        receivedFrames = 0
        droppedFrames = 0
        lastVideoSequence = nil
        lastVideoArrival = nil
        lastVideoPresentation = nil
        lastKeyFrameRequest = nil
        consecutiveVideoFailures = 0
        pendingPings.removeAll(keepingCapacity: true)
        Task {
            await control?.cancel()
            await video?.cancel()
            await input?.cancel()
        }
    }

    private func recordFrameArrival(_ frame: EncodedVideoFrame) {
        let arrival = DispatchTime.now().uptimeNanoseconds
        if let previousSequence = lastVideoSequence, frame.sequence > previousSequence + 1 {
            droppedFrames += Int(clamping: frame.sequence - previousSequence - 1)
            if !frame.isKeyFrame { requestKeyFrame(at: arrival) }
        }
        if let previousArrival = lastVideoArrival,
           let previousPresentation = lastVideoPresentation,
           frame.presentationTimeNanoseconds > previousPresentation {
            let arrivalInterval = Int64(clamping: arrival - previousArrival)
            let presentationInterval = Int64(clamping: frame.presentationTimeNanoseconds - previousPresentation)
            let variation = Double(abs(arrivalInterval - presentationInterval)) / 1_000_000
            metrics.jitterMilliseconds = metrics.jitterMilliseconds == 0
                ? variation
                : (metrics.jitterMilliseconds * 0.9) + (variation * 0.1)
        }
        lastVideoSequence = frame.sequence
        lastVideoArrival = arrival
        lastVideoPresentation = frame.presentationTimeNanoseconds
        if frame.isKeyFrame { lastKeyFrameRequest = nil }
    }

    private func requestKeyFrame(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let minimumInterval: UInt64 = 250_000_000
        guard lastKeyFrameRequest.map({ now >= $0 + minimumInterval }) ?? true else { return }
        lastKeyFrameRequest = now
        send(.requestKeyFrame)
    }

    private static func loadIdentity() -> LocalIdentity {
        let key = "nuboiPadDeviceID"
        let defaults = UserDefaults.standard
        let id: UUID
        if let stored = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            id = stored
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: key)
        }
        return LocalIdentity(id: id, name: UIDevice.current.name)
    }
}
