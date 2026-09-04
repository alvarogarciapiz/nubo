@preconcurrency import Network
import NuboCore

public enum EndpointResolver {
    public static func networkEndpoint(for endpoint: ConnectionEndpoint) -> NWEndpoint {
        switch endpoint {
        case let .bonjour(serviceName, domain):
            .service(name: serviceName, type: NuboConstants.serviceType, domain: domain, interface: nil)
        case let .manual(host, port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .http)
        }
    }
}
