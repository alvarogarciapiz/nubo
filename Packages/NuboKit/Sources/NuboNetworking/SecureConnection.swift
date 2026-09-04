@preconcurrency import Network
import CryptoKit
import Foundation
import NuboCore
import NuboProtocol

public enum SecureChannelKind: String, Codable, Sendable {
    case control
    case input
    case video
    case audio
}

public struct PairingHello: Codable, Sendable {
    public let protocolVersion: UInt16
    public let deviceID: UUID
    public let deviceName: String
    public let publicKey: Data
    public let nonce: Data

    public init(protocolVersion: UInt16 = NuboConstants.protocolVersion, deviceID: UUID, deviceName: String, challenge: PairingChallenge) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = challenge.publicKey
        self.nonce = challenge.nonce
    }
}

public struct ResumeHello: Codable, Sendable {
    public let protocolVersion: UInt16
    public let deviceID: UUID
    public let channel: SecureChannelKind
    public let nonce: Data
    public let proof: Data

    public init(protocolVersion: UInt16 = NuboConstants.protocolVersion, deviceID: UUID, channel: SecureChannelKind, nonce: Data, proof: Data) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.channel = channel
        self.nonce = nonce
        self.proof = proof
    }
}

public struct ResumeAcceptance: Codable, Sendable {
    public let protocolVersion: UInt16
    public let nonce: Data
    public let proof: Data

    public init(protocolVersion: UInt16 = NuboConstants.protocolVersion, nonce: Data, proof: Data) {
        self.protocolVersion = protocolVersion
        self.nonce = nonce
        self.proof = proof
    }
}

public enum BootstrapMessage: Codable, Sendable {
    case pairingHello(PairingHello)
    case pairingDecision(Bool)
    case resumeHello(ResumeHello)
    case resumeAccepted(ResumeAcceptance)
    case rejected(String)
}

public enum SecureConnectionError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case oversizedFrame(Int)
    case invalidBootstrap
    case authenticationFailed
    case replayedFrame
    case pairingRejected
    case unsupportedProtocolVersion(UInt16)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(reason): reason
        case .connectionClosed: "Connection closed"
        case let .oversizedFrame(size): "Frame is too large (\(size) bytes)"
        case .invalidBootstrap: "Invalid connection handshake"
        case .authenticationFailed: "Peer authentication failed"
        case .replayedFrame: "Duplicate or out-of-order encrypted frame"
        case .pairingRejected: "Pairing was rejected"
        case let .unsupportedProtocolVersion(version): "Unsupported Nubo protocol version \(version)"
        }
    }
}

public final class NetworkFrameConnection: @unchecked Sendable {
    public static let maximumFrameLength = 40 * 1_024 * 1_024

    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, label: String = "com.lvrpiz.nubo.connection") {
        self.connection = connection
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    public convenience init(endpoint: ConnectionEndpoint, label: String = "com.lvrpiz.nubo.connection", serviceClass: NWParameters.ServiceClass = .responsiveData) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = serviceClass
        self.init(connection: NWConnection(to: EndpointResolver.networkEndpoint(for: endpoint), using: parameters), label: label)
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume()
                case let .failed(error):
                    gate.resume(throwing: SecureConnectionError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    gate.resume(throwing: SecureConnectionError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func sendFrame(_ data: Data) async throws {
        guard data.count <= Self.maximumFrameLength else { throw SecureConnectionError.oversizedFrame(data.count) }
        var packet = Data()
        packet.appendInteger(UInt32(data.count))
        packet.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SecureConnectionError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveFrame() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = Int(header.readInteger(UInt32.self))
        guard length <= Self.maximumFrameLength else { throw SecureConnectionError.oversizedFrame(length) }
        return try await receiveExactly(length)
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var result = Data()
        while result.count < length {
            let remaining = length - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: SecureConnectionError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: SecureConnectionError.connectionClosed)
                    } else {
                        continuation.resume(throwing: SecureConnectionError.connectionClosed)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

public actor EncryptedMessageConnection {
    private let connection: NetworkFrameConnection
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let codec = MessageCodec()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(connection: NetworkFrameConnection, keys: SessionKeys) {
        self.connection = connection
        self.sendKey = keys.send
        self.receiveKey = keys.receive
    }

    public func send(_ message: NuboMessage) async throws {
        let plaintext = try codec.encode(message)
        let counter = sendCounter
        sendCounter &+= 1
        let nonce = try ChaChaPoly.Nonce(data: nonceData(counter))
        let counterData = integerData(counter)
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce, authenticating: counterData)
        try await connection.sendFrame(counterData + box.ciphertext + box.tag)
    }

    public func receive() async throws -> NuboMessage {
        let packet = try await connection.receiveFrame()
        guard packet.count >= 8 + 16 else { throw SecureConnectionError.authenticationFailed }
        let counter = packet.prefix(8).readInteger(UInt64.self)
        guard counter == receiveCounter else { throw SecureConnectionError.replayedFrame }
        let counterData = Data(packet.prefix(8))
        let encrypted = Data(packet.dropFirst(8).dropLast(16))
        let tag = Data(packet.suffix(16))
        let nonce = try ChaChaPoly.Nonce(data: nonceData(counter))
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: encrypted, tag: tag)
        let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: counterData)
        receiveCounter &+= 1
        var wireDecoder = WireDecoder()
        guard let envelope = try wireDecoder.append(plaintext).first else { throw SecureConnectionError.invalidBootstrap }
        return try codec.decode(envelope)
    }

    public func cancel() { connection.cancel() }
}

public struct SessionKeys: Sendable {
    fileprivate let send: SymmetricKey
    fileprivate let receive: SymmetricKey

    public static func derive(secret: Data, clientNonce: Data, serverNonce: Data, isClient: Bool) -> SessionKeys {
        let master = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: clientNonce + serverNonce,
            info: Data("Nubo secure channel v1".utf8),
            outputByteCount: 32
        )
        let clientToServer = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("client to server".utf8), outputByteCount: 32)
        let serverToClient = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("server to client".utf8), outputByteCount: 32)
        return isClient
            ? SessionKeys(send: clientToServer, receive: serverToClient)
            : SessionKeys(send: serverToClient, receive: clientToServer)
    }
}

public enum PeerAuthentication {
    public static func clientProof(secret: Data, deviceID: UUID, channel: SecureChannelKind, nonce: Data) -> Data {
        authenticate(secret: secret, data: Data("client|\(deviceID.uuidString)|\(channel.rawValue)|".utf8) + nonce)
    }

    public static func serverProof(secret: Data, deviceID: UUID, channel: SecureChannelKind, clientNonce: Data, serverNonce: Data) -> Data {
        authenticate(secret: secret, data: Data("server|\(deviceID.uuidString)|\(channel.rawValue)|".utf8) + clientNonce + serverNonce)
    }

    public static func verify(_ proof: Data, matches expected: Data) -> Bool {
        proof.count == expected.count && proof.withUnsafeBytes { (lhs: UnsafeRawBufferPointer) in
            expected.withUnsafeBytes { (rhs: UnsafeRawBufferPointer) in
                var difference: UInt8 = 0
                for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
                return difference == 0
            }
        }
    }

    public static func randomNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func authenticate(secret: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
    }
}

public extension NetworkFrameConnection {
    func sendBootstrap(_ message: BootstrapMessage) async throws {
        try await sendFrame(JSONEncoder().encode(message))
    }

    func receiveBootstrap() async throws -> BootstrapMessage {
        try await JSONDecoder().decode(BootstrapMessage.self, from: receiveFrame())
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

    func resume() { take()?.resume() }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

private func integerData<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func nonceData(_ counter: UInt64) -> Data {
    Data(repeating: 0, count: 4) + integerData(counter)
}

private extension DataProtocol {
    func readInteger<T: FixedWidthInteger>(_ type: T.Type) -> T {
        prefix(MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        append(integerData(value))
    }
}
