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
    var path: [ConnectionEndpoint] = []
    var connectionState: ConnectionState = .idle
    var selectedHostName = ""
    var showManualConnection = false
    var showSettings = false
    var pairingPeerName = ""
    var pairingCode = ""
    var showPairingConfirmation = false
    var displays: [DisplayDescriptor] = []
    var metrics = ConnectionMetrics()

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
    @ObservationIgnored private let clipboardGuard = ClipboardLoopGuard()
    @ObservationIgnored private var activeEndpoint: ConnectionEndpoint?
    @ObservationIgnored private var activePeerID: UUID?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0

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
                self?.hosts = hosts
            }
        }
    }

    func connect(to host: DiscoveredHost) {
        selectedHostName = host.name
        path.append(host.endpoint)
        connectionState = .connecting
        beginConnection(endpoint: host.endpoint, expectedPeerID: host.peerID)
    }

    func connectManually(host: String, port: Int) throws {
        let endpoint = try ManualEndpoint(host: host, port: port)
        selectedHostName = endpoint.host
        path.append(endpoint.endpoint)
        connectionState = .connecting
        showManualConnection = false
        beginConnection(endpoint: endpoint.endpoint, expectedPeerID: nil)
    }

    func disconnect() {
        activeEndpoint = nil
        activePeerID = nil
        reconnectTask?.cancel()
        connectionTask?.cancel()
        cancelTransport()
        path.removeAll()
        connectionState = .idle
    }

    func decidePairing(_ accepted: Bool) {
        showPairingConfirmation = false
        pairingContinuation?.resume(returning: accepted)
        pairingContinuation = nil
    }

    func send(_ message: NuboMessage) {
        if message.channel == .input {
            enqueueInput(message)
            return
        }
        guard let connection = session?.control else { return }
        Task {
            do { try await connection.send(message) }
            catch { connectionFailed(error) }
        }
    }

    func sendClipboard() {
        guard UserDefaults.standard.object(forKey: "clipboardSync") as? Bool ?? true,
              let text = UIPasteboard.general.string else { return }
        send(.clipboardText(id: UUID(), text: text))
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startDiscovery()
            if case .reconnecting = connectionState, let endpoint = activeEndpoint {
                beginConnection(endpoint: endpoint, expectedPeerID: activePeerID, resetsBackoff: false)
            }
        case .background:
            discovery.stop()
            discoveryTask?.cancel()
            if connectionState != .idle {
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
                guard !Task.isCancelled else { await session.control.cancel(); return }
                self.session = session
                self.activePeerID = session.peerID
                self.reconnectAttempt = 0
                self.reconnectTask = nil
                self.selectedHostName = session.peerName
                async let input = sessionClient.resume(endpoint: endpoint, identity: identity, credential: session.credential, channel: .input)
                async let video = sessionClient.resume(endpoint: endpoint, identity: identity, credential: session.credential, channel: .video)
                let (inputConnection, videoConnection) = try await (input, video)
                guard !Task.isCancelled else {
                    await inputConnection.cancel()
                    await videoConnection.cancel()
                    await session.control.cancel()
                    return
                }
                self.inputConnection = inputConnection
                self.videoConnection = videoConnection
                self.startReceiveLoop(session.control)
                self.startMetrics()
                self.startVideoReceiveLoop(videoConnection)
                self.connectionState = .connected
            } catch {
                self.connectionFailed(error)
            }
        }
    }

    private func requestPairingApproval(name: String, code: String) async -> Bool {
        pairingPeerName = name
        pairingCode = code
        connectionState = .pairing(code: code)
        showPairingConfirmation = true
        return await withCheckedContinuation { pairingContinuation = $0 }
    }

    private func startReceiveLoop(_ connection: EncryptedMessageConnection) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    self?.handle(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(error)
            }
        }
    }

    private func startVideoReceiveLoop(_ connection: EncryptedMessageConnection) {
        videoReceiveTask?.cancel()
        videoReceiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    self?.handleVideo(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(error)
            }
        }
    }

    private func handleVideo(_ message: NuboMessage) {
        do {
            switch message {
            case let .videoConfiguration(configuration):
                if configuration.parameterSets != videoParameterSets {
                    try decoder.configure(parameterSets: configuration.parameterSets)
                    videoParameterSets = configuration.parameterSets
                }
            case let .videoFrame(frame):
                receivedVideoBytes += frame.bytes.count
                receivedFrames += 1
                try decoder.decode(VideoPacket(
                    data: frame.bytes,
                    presentationTime: CMTime(value: Int64(clamping: frame.presentationTimeNanoseconds), timescale: 1_000_000_000),
                    isKeyFrame: frame.isKeyFrame
                ))
            default:
                break
            }
        } catch {
            connectionState = .unavailable(reason: "Video decode failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ message: NuboMessage) {
        switch message {
        case let .pong(sentAt):
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= sentAt { metrics.rttMilliseconds = Double(now - sentAt) / 1_000_000 }
        case let .displays(displays):
            self.displays = displays
        case let .clipboardText(_, text):
            Task { [clipboardGuard] in
                await clipboardGuard.markRemoteText(text)
                UIPasteboard.general.string = text
            }
        case let .disconnect(reason):
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
                receivedVideoBytes = 0
                receivedFrames = 0
                let sentAt = DispatchTime.now().uptimeNanoseconds
                send(.ping(sentAt))
                send(.networkStats(metrics))
            }
        }
    }

    private func connectionFailed(_ error: any Error) {
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

    private func enqueueInput(_ message: NuboMessage) {
        guard inputConnection != nil else { return }
        if case let .pointer(.relativeMotion(next)) = message,
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
                    self.connectionFailed(error)
                    return
                }
            }
            self.inputSendTask = nil
        }
    }

    private func cancelTransport() {
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
        Task {
            await control?.cancel()
            await video?.cancel()
            await input?.cancel()
        }
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
