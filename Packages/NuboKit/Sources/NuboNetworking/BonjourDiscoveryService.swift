@preconcurrency import Network
import Foundation
import NuboCore

public final class BonjourDiscoveryService: DiscoveryService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lvrpiz.nubo.discovery", qos: .utility)
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var currentHosts: [DiscoveredHost] = []
    private var continuations: [UUID: AsyncStream<[DiscoveredHost]>.Continuation] = [:]
    private var shouldRun = false

    public init() {}

    public func hosts() -> AsyncStream<[DiscoveredHost]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(currentHosts)
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    public func start() {
        lock.withLock {
            shouldRun = true
            guard browser == nil else { return }
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: NuboConstants.serviceType, domain: nil),
                using: parameters
            )
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let browser else { return }
                self?.update(results, from: browser)
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                if case let .failed(error) = state {
                    NuboLog.networking.error("Bonjour discovery failed: \(error.localizedDescription, privacy: .public)")
                    guard let browser else { return }
                    self?.recover(from: browser)
                }
            }
            self.browser = browser
            browser.start(queue: queue)
        }
    }

    public func stop() {
        let browser = lock.withLock { () -> NWBrowser? in
            shouldRun = false
            defer { self.browser = nil }
            return self.browser
        }
        browser?.cancel()
        publish([])
    }

    private func update(_ results: Set<NWBrowser.Result>, from source: NWBrowser) {
        let hosts = results.compactMap { result -> DiscoveredHost? in
            guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
            let metadata: (UUID?, UInt16?) = if case let .bonjour(record) = result.metadata {
                (record.stringValue(for: "id").flatMap(UUID.init(uuidString:)), record.stringValue(for: "v").flatMap(UInt16.init))
            } else {
                (nil, nil)
            }
            return DiscoveredHost(
                name: name,
                endpoint: .bonjour(serviceName: name, domain: domain),
                protocolVersion: metadata.1,
                peerID: metadata.0
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let continuations = lock.withLock { () -> [AsyncStream<[DiscoveredHost]>.Continuation] in
            guard shouldRun, browser === source else { return [] }
            currentHosts = hosts
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(hosts) }
    }

    private func publish(_ hosts: [DiscoveredHost]) {
        let continuations = lock.withLock { () -> [AsyncStream<[DiscoveredHost]>.Continuation] in
            currentHosts = hosts
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(hosts) }
    }

    private func removeContinuation(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }

    private func recover(from failedBrowser: NWBrowser) {
        let restart = lock.withLock { () -> Bool in
            guard browser === failedBrowser else { return false }
            browser = nil
            return shouldRun
        }
        failedBrowser.cancel()
        guard restart else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.start()
        }
    }
}

private extension NWTXTRecord {
    func stringValue(for key: String) -> String? {
        guard case let .string(value) = getEntry(for: key) else { return nil }
        return value
    }
}
