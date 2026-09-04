@preconcurrency import Network
import Foundation
import NuboCore
import NuboProtocol

public struct LocalIdentity: Codable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ClientSecureSession: Sendable {
    public let peerID: UUID
    public let peerName: String
    public let credential: PairedCredential
    public let control: EncryptedMessageConnection
}

public enum HostEvent: Sendable {
    case listening(UInt16)
    case pairingRequested(requestID: UUID, peerName: String, code: String)
    case authenticated(peerID: UUID, peerName: String, channel: SecureChannelKind)
    case message(peerID: UUID, NuboMessage)
    case disconnected(peerID: UUID, reason: String)
    case failed(String)
}

public final class SecureSessionClient: Sendable {
    private let credentialStore: any CredentialStore

    public init(credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    public func connect(
        to endpoint: ConnectionEndpoint,
        identity: LocalIdentity,
        expectedPeerID: UUID?,
        approvePairing: @escaping @Sendable (_ peerName: String, _ code: String) async -> Bool
    ) async throws -> ClientSecureSession {
        if let expectedPeerID, let credential = try await credentialStore.credential(for: expectedPeerID) {
            let control = try await resume(endpoint: endpoint, identity: identity, credential: credential, channel: .control)
            return ClientSecureSession(peerID: expectedPeerID, peerName: credential.peerName, credential: credential, control: control)
        }
        return try await pair(endpoint: endpoint, identity: identity, approvePairing: approvePairing)
    }

    public func resume(
        endpoint: ConnectionEndpoint,
        identity: LocalIdentity,
        credential: PairedCredential,
        channel: SecureChannelKind
    ) async throws -> EncryptedMessageConnection {
        let connection = NetworkFrameConnection(
            endpoint: endpoint,
            label: "com.lvrpiz.nubo.client.\(channel.rawValue)",
            serviceClass: channel == .video ? .interactiveVideo : .responsiveData
        )
        try await connection.start()
        let clientNonce = PeerAuthentication.randomNonce()
        let proof = PeerAuthentication.clientProof(secret: credential.sharedSecret, deviceID: identity.id, channel: channel, nonce: clientNonce)
        try await connection.sendBootstrap(.resumeHello(.init(deviceID: identity.id, channel: channel, nonce: clientNonce, proof: proof)))
        guard case let .resumeAccepted(acceptance) = try await connection.receiveBootstrap() else {
            throw SecureConnectionError.authenticationFailed
        }
        guard acceptance.protocolVersion == NuboConstants.protocolVersion else {
            throw SecureConnectionError.unsupportedProtocolVersion(acceptance.protocolVersion)
        }
        let expected = PeerAuthentication.serverProof(secret: credential.sharedSecret, deviceID: identity.id, channel: channel, clientNonce: clientNonce, serverNonce: acceptance.nonce)
        guard PeerAuthentication.verify(acceptance.proof, matches: expected) else {
            throw SecureConnectionError.authenticationFailed
        }
        let keys = SessionKeys.derive(secret: credential.sharedSecret, clientNonce: clientNonce, serverNonce: acceptance.nonce, isClient: true)
        return EncryptedMessageConnection(connection: connection, keys: keys)
    }

    private func pair(
        endpoint: ConnectionEndpoint,
        identity: LocalIdentity,
        approvePairing: @escaping @Sendable (String, String) async -> Bool
    ) async throws -> ClientSecureSession {
        let connection = NetworkFrameConnection(endpoint: endpoint, label: "com.lvrpiz.nubo.client.pairing")
        try await connection.start()
        let challenge = PairingChallenge()
        try await connection.sendBootstrap(.pairingHello(.init(deviceID: identity.id, deviceName: identity.name, challenge: challenge)))
        guard case let .pairingHello(peerHello) = try await connection.receiveBootstrap() else {
            throw SecureConnectionError.invalidBootstrap
        }
        guard peerHello.protocolVersion == NuboConstants.protocolVersion else {
            throw SecureConnectionError.unsupportedProtocolVersion(peerHello.protocolVersion)
        }
        let agreement = try PairingKeyAgreement.deriveSecret(local: challenge, peerPublicKey: peerHello.publicKey, peerNonce: peerHello.nonce)
        let approved = await approvePairing(peerHello.deviceName, agreement.confirmationCode)
        try await connection.sendBootstrap(.pairingDecision(approved))
        guard case let .pairingDecision(peerApproved) = try await connection.receiveBootstrap(), approved, peerApproved else {
            connection.cancel()
            throw SecureConnectionError.pairingRejected
        }
        let credential = PairedCredential(peerID: peerHello.deviceID, peerName: peerHello.deviceName, sharedSecret: agreement.secret)
        try await credentialStore.save(credential)
        let keys = SessionKeys.derive(secret: agreement.secret, clientNonce: challenge.nonce, serverNonce: peerHello.nonce, isClient: true)
        return ClientSecureSession(peerID: peerHello.deviceID, peerName: peerHello.deviceName, credential: credential, control: EncryptedMessageConnection(connection: connection, keys: keys))
    }
}

public actor NuboHostServer {
    private let identity: LocalIdentity
    private let credentialStore: any CredentialStore
    private let queue = DispatchQueue(label: "com.lvrpiz.nubo.listener", qos: .userInteractive)
    private var listener: NWListener?
    private var continuations: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    private var pairingDecisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var connections: [UUID: [SecureChannelKind: EncryptedMessageConnection]] = [:]
    private var peerNames: [UUID: String] = [:]

    public init(identity: LocalIdentity, credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.identity = identity
        self.credentialStore = credentialStore
    }

    public func events() -> AsyncStream<HostEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        }
    }

    public func start(port: UInt16 = NuboConstants.defaultPort) throws {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.service = NWListener.Service(
            name: identity.name,
            type: NuboConstants.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(["id": identity.id.uuidString, "v": String(NuboConstants.protocolVersion)])
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task {
                switch state {
                case .ready: await self?.emit(.listening(port))
                case let .failed(error): await self?.listenerFailed(error)
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for channels in connections.values {
            for connection in channels.values { Task { await connection.cancel() } }
        }
        connections.removeAll()
    }

    public func decidePairing(requestID: UUID, accepted: Bool) {
        pairingDecisions.removeValue(forKey: requestID)?.resume(returning: accepted)
    }

    public func send(_ message: NuboMessage, to peerID: UUID, channel: SecureChannelKind) async throws {
        guard let connection = connections[peerID]?[channel] else { throw SecureConnectionError.connectionClosed }
        try await connection.send(message)
    }

    private func accept(_ nwConnection: NWConnection) async {
        let framed = NetworkFrameConnection(connection: nwConnection, label: "com.lvrpiz.nubo.host.peer")
        do {
            try await framed.start()
            switch try await framed.receiveBootstrap() {
            case let .pairingHello(hello):
                try await acceptPairing(hello, connection: framed)
            case let .resumeHello(hello):
                try await acceptResume(hello, connection: framed)
            default:
                try await framed.sendBootstrap(.rejected("Unexpected handshake"))
                framed.cancel()
            }
        } catch {
            framed.cancel()
            emit(.failed(error.localizedDescription))
        }
    }

    private func acceptPairing(_ hello: PairingHello, connection: NetworkFrameConnection) async throws {
        guard hello.protocolVersion == NuboConstants.protocolVersion else {
            try await connection.sendBootstrap(.rejected("Unsupported protocol version"))
            throw SecureConnectionError.unsupportedProtocolVersion(hello.protocolVersion)
        }
        guard activeControlPeerID == nil || activeControlPeerID == hello.deviceID else {
            try await connection.sendBootstrap(.rejected("Mac is already in use"))
            throw SecureConnectionError.connectionFailed("Mac is already in use")
        }
        let challenge = PairingChallenge()
        try await connection.sendBootstrap(.pairingHello(.init(deviceID: identity.id, deviceName: identity.name, challenge: challenge)))
        let agreement = try PairingKeyAgreement.deriveSecret(local: challenge, peerPublicKey: hello.publicKey, peerNonce: hello.nonce)
        let requestID = UUID()
        emit(.pairingRequested(requestID: requestID, peerName: hello.deviceName, code: agreement.confirmationCode))
        let locallyApproved = await withCheckedContinuation { continuation in pairingDecisions[requestID] = continuation }
        try await connection.sendBootstrap(.pairingDecision(locallyApproved))
        guard case let .pairingDecision(peerApproved) = try await connection.receiveBootstrap(), locallyApproved, peerApproved else {
            throw SecureConnectionError.pairingRejected
        }
        let credential = PairedCredential(peerID: hello.deviceID, peerName: hello.deviceName, sharedSecret: agreement.secret)
        try await credentialStore.save(credential)
        peerNames[hello.deviceID] = hello.deviceName
        let keys = SessionKeys.derive(secret: agreement.secret, clientNonce: hello.nonce, serverNonce: challenge.nonce, isClient: false)
        let secure = EncryptedMessageConnection(connection: connection, keys: keys)
        store(secure, peerID: hello.deviceID, channel: .control)
    }

    private func acceptResume(_ hello: ResumeHello, connection: NetworkFrameConnection) async throws {
        guard hello.protocolVersion == NuboConstants.protocolVersion else {
            try await connection.sendBootstrap(.rejected("Unsupported protocol version"))
            throw SecureConnectionError.unsupportedProtocolVersion(hello.protocolVersion)
        }
        if hello.channel == .control {
            guard activeControlPeerID == nil || activeControlPeerID == hello.deviceID else {
                try await connection.sendBootstrap(.rejected("Mac is already in use"))
                throw SecureConnectionError.connectionFailed("Mac is already in use")
            }
        } else {
            guard connections[hello.deviceID]?[.control] != nil else {
                try await connection.sendBootstrap(.rejected("Control session required"))
                throw SecureConnectionError.authenticationFailed
            }
        }
        guard let credential = try await credentialStore.credential(for: hello.deviceID) else {
            try await connection.sendBootstrap(.rejected("Unknown peer"))
            throw SecureConnectionError.authenticationFailed
        }
        let expected = PeerAuthentication.clientProof(secret: credential.sharedSecret, deviceID: hello.deviceID, channel: hello.channel, nonce: hello.nonce)
        guard PeerAuthentication.verify(hello.proof, matches: expected) else { throw SecureConnectionError.authenticationFailed }
        let serverNonce = PeerAuthentication.randomNonce()
        let proof = PeerAuthentication.serverProof(secret: credential.sharedSecret, deviceID: hello.deviceID, channel: hello.channel, clientNonce: hello.nonce, serverNonce: serverNonce)
        try await connection.sendBootstrap(.resumeAccepted(.init(nonce: serverNonce, proof: proof)))
        peerNames[hello.deviceID] = credential.peerName
        let keys = SessionKeys.derive(secret: credential.sharedSecret, clientNonce: hello.nonce, serverNonce: serverNonce, isClient: false)
        store(EncryptedMessageConnection(connection: connection, keys: keys), peerID: hello.deviceID, channel: hello.channel)
    }

    private func store(_ connection: EncryptedMessageConnection, peerID: UUID, channel: SecureChannelKind) {
        connections[peerID, default: [:]][channel] = connection
        emit(.authenticated(peerID: peerID, peerName: peerNames[peerID] ?? "iPad", channel: channel))
        if channel == .control || channel == .input {
            Task { await receiveLoop(connection, peerID: peerID, channel: channel) }
        }
    }

    private func receiveLoop(_ connection: EncryptedMessageConnection, peerID: UUID, channel: SecureChannelKind) async {
        do {
            while true { emit(.message(peerID: peerID, try await connection.receive())) }
        } catch {
            let isCurrentConnection = connections[peerID]?[channel] === connection
            if isCurrentConnection { connections[peerID]?[channel] = nil }
            if channel == .control, isCurrentConnection {
                if let remaining = connections.removeValue(forKey: peerID) {
                    for connection in remaining.values { Task { await connection.cancel() } }
                }
                emit(.disconnected(peerID: peerID, reason: error.localizedDescription))
            }
        }
    }

    private var activeControlPeerID: UUID? {
        connections.first(where: { $0.value[.control] != nil })?.key
    }

    private func listenerFailed(_ error: NWError) {
        listener = nil
        emit(.failed(error.localizedDescription))
    }

    private func emit(_ event: HostEvent) { continuations.values.forEach { $0.yield(event) } }
    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
}
