import Foundation
import NuboCore

public enum ConnectionEndpoint: Hashable, Codable, Sendable, Identifiable {
    case bonjour(serviceName: String, domain: String)
    case manual(host: String, port: UInt16)

    public var id: String {
        switch self {
        case let .bonjour(serviceName, domain):
            "bonjour:\(serviceName).\(domain)"
        case let .manual(host, port):
            "manual:\(host):\(port)"
        }
    }

    public var displayName: String {
        switch self {
        case let .bonjour(serviceName, _): serviceName
        case let .manual(host, _): host
        }
    }
}

public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: ConnectionEndpoint
    public let protocolVersion: UInt16?
    public let peerID: UUID?

    public init(name: String, endpoint: ConnectionEndpoint, protocolVersion: UInt16? = nil, peerID: UUID? = nil) {
        self.id = endpoint.id
        self.name = name
        self.endpoint = endpoint
        self.protocolVersion = protocolVersion
        self.peerID = peerID
    }
}

public protocol DiscoveryService: Sendable {
    func hosts() -> AsyncStream<[DiscoveredHost]>
    func start()
    func stop()
}

public enum EndpointValidationError: Error, Equatable {
    case emptyHost
    case invalidPort
}

public struct ManualEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: Int) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw EndpointValidationError.emptyHost }
        guard (1...65_535).contains(port), let validPort = UInt16(exactly: port) else {
            throw EndpointValidationError.invalidPort
        }
        self.host = trimmedHost
        self.port = validPort
    }

    public var endpoint: ConnectionEndpoint { .manual(host: host, port: port) }
}
