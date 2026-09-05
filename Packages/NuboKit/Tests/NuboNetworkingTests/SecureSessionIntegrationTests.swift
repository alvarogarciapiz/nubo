import Foundation
import NuboNetworking
import NuboProtocol
import XCTest

final class SecureSessionIntegrationTests: XCTestCase {
    func testPreviewRequiresSavedTrustAndCannotInjectInput() async throws {
        let clientID = UUID()
        let hostID = UUID()
        let secret = Data(repeating: 42, count: 32)
        let hostStore = MemoryCredentialStore()
        let clientStore = MemoryCredentialStore()
        try await hostStore.save(.init(peerID: clientID, peerName: "iPad", sharedSecret: secret))
        let credential = PairedCredential(peerID: hostID, peerName: "Mac", sharedSecret: secret)
        try await clientStore.save(credential)
        let host = NuboHostServer(identity: .init(id: hostID, name: "Mac"), credentialStore: hostStore)
        let events = await host.events()
        let observer = Task {
            for await event in events {
                switch event {
                case let .message(peerID, .previewRequest):
                    try await host.send(.previewImage(jpeg: Data([1, 2, 3]), capturedAt: Date(timeIntervalSince1970: 0)), to: peerID, channel: .preview)
                case .message(_, .pointer): XCTFail("Preview channel forwarded input")
                case .pairingRequested: XCTFail("A preview must never request pairing")
                default: break
                }
            }
        }
        let port = UInt16.random(in: 54_000...59_000)
        try await host.start(port: port)
        try await Task.sleep(for: .milliseconds(50))
        let client = SecureSessionClient(credentialStore: clientStore)
        let endpoint = ConnectionEndpoint.manual(host: "127.0.0.1", port: port)
        do {
            _ = try await client.resume(endpoint: endpoint, identity: .init(id: UUID(), name: "Unknown"), credential: credential, channel: .preview)
            XCTFail("Unknown device accessed preview")
        } catch { /* Expected: unknown device has no host-side trust. */ }
        let preview = try await client.resume(endpoint: endpoint, identity: .init(id: clientID, name: "iPad"), credential: credential, channel: .preview)
        try await preview.send(.previewRequest)
        let response = try await preview.receive()
        XCTAssertEqual(response, .previewImage(jpeg: Data([1, 2, 3]), capturedAt: Date(timeIntervalSince1970: 0)))
        try await preview.send(.pointer(.relativeMotion(.init(dx: 1, dy: 1))))
        do {
            _ = try await preview.receive()
            XCTFail("Input sent over preview should close that channel")
        } catch { /* Host rejected the wrong channel. */ }
        try await client.forget(peerID: hostID)
        let forgotten = try await client.savedCredential(for: hostID)
        XCTAssertNil(forgotten)
        await preview.cancel()
        await host.stop()
        observer.cancel()
    }
    func testDeniedPairingDoesNotPersistCredentials() async throws {
        let hostID = UUID()
        let clientID = UUID()
        let hostStore = MemoryCredentialStore()
        let clientStore = MemoryCredentialStore()
        let host = NuboHostServer(identity: .init(id: hostID, name: "Mac"), credentialStore: hostStore)
        let events = await host.events()
        let observer = Task {
            for await event in events {
                if case let .pairingRequested(id, _, _) = event {
                    await host.decidePairing(requestID: id, accepted: false)
                }
            }
        }
        let port = UInt16.random(in: 54_000...59_000)
        try await host.start(port: port)
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await SecureSessionClient(credentialStore: clientStore).connect(
                to: .manual(host: "127.0.0.1", port: port), identity: .init(id: clientID, name: "iPad"), expectedPeerID: nil,
                approvePairing: { _, _ in true }
            )
            XCTFail("A denied request must never connect")
        } catch { /* Denial closes the unauthenticated connection. */ }
        let hostCredential = try await hostStore.credential(for: clientID)
        let clientCredential = try await clientStore.credential(for: hostID)
        XCTAssertNil(hostCredential)
        XCTAssertNil(clientCredential)
        await host.stop()
        observer.cancel()
    }
    func testPairingAndEncryptedRoundTripOnLoopback() async throws {
        let port = UInt16.random(in: 54_000...59_000)
        let hostStore = MemoryCredentialStore()
        let clientStore = MemoryCredentialStore()
        let host = NuboHostServer(identity: .init(id: UUID(), name: "Test Mac"), credentialStore: hostStore)
        let events = await host.events()

        let hostTask = Task {
            for await event in events {
                switch event {
                case let .pairingRequested(requestID, _, _):
                    await host.decidePairing(requestID: requestID, accepted: true)
                case let .message(peerID, .ping(value)):
                    try await host.send(.pong(value), to: peerID, channel: .control)
                case let .message(peerID, .pointer(event)):
                    try await host.send(.pointer(event), to: peerID, channel: .input)
                case let .message(peerID, .clipboardText(id, text)):
                    try await host.send(.clipboardText(id: id, text: text), to: peerID, channel: .control)
                default:
                    break
                }
            }
        }

        try await host.start(port: port)
        try await Task.sleep(for: .milliseconds(50))
        let client = SecureSessionClient(credentialStore: clientStore)
        let clientIdentity = LocalIdentity(id: UUID(), name: "Test iPad")
        let session = try await client.connect(
            to: .manual(host: "127.0.0.1", port: port),
            identity: clientIdentity,
            expectedPeerID: nil,
            approvePairing: { _, code in code.count == 6 }
        )
        try await session.control.send(.ping(99))
        let response = try await session.control.receive()
        XCTAssertEqual(response, .pong(99))

        await session.control.cancel()

        let resumed = try await client.connect(
            to: .manual(host: "127.0.0.1", port: port),
            identity: clientIdentity,
            expectedPeerID: session.peerID,
            approvePairing: { _, _ in false }
        )
        try await resumed.control.send(.ping(100))
        let resumedResponse = try await resumed.control.receive()
        XCTAssertEqual(resumedResponse, .pong(100))

        let input = try await client.resume(
            endpoint: .manual(host: "127.0.0.1", port: port),
            identity: clientIdentity,
            credential: resumed.credential,
            channel: .input
        )
        let pointerMessage = NuboMessage.pointer(.relativeMotion(.init(dx: 2, dy: -3)))
        try await input.send(pointerMessage)
        let inputResponse = try await input.receive()
        XCTAssertEqual(inputResponse, pointerMessage)

        var roundTripMilliseconds: [Double] = []
        for sequence in 0..<100 {
            let started = DispatchTime.now().uptimeNanoseconds
            try await resumed.control.send(.ping(UInt64(sequence)))
            let pong = try await resumed.control.receive()
            XCTAssertEqual(pong, .pong(UInt64(sequence)))
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            roundTripMilliseconds.append(Double(elapsed) / 1_000_000)
        }
        let sortedRTT = roundTripMilliseconds.sorted()
        let p50 = sortedRTT[sortedRTT.count / 2]
        let p95 = sortedRTT[Int(Double(sortedRTT.count - 1) * 0.95)]
        print(String(format: "Nubo encrypted loopback RTT: p50 %.3f ms, p95 %.3f ms", p50, p95))
        XCTAssertLessThan(p95, 20, "Encrypted control traffic should remain interactive on loopback")

        let payload = String(repeating: "A", count: 1_024 * 1_024)
        let throughputStarted = DispatchTime.now().uptimeNanoseconds
        for sequence in 0..<8 {
            let message = NuboMessage.clipboardText(id: UUID(), text: payload)
            try await resumed.control.send(message)
            let echo = try await resumed.control.receive()
            XCTAssertEqual(echo, message, "Iteration \(sequence) must round-trip intact")
        }
        let throughputSeconds = Double(DispatchTime.now().uptimeNanoseconds - throughputStarted) / 1_000_000_000
        let aggregateMbps = Double(payload.utf8.count * 8 * 2 * 8) / throughputSeconds / 1_000_000
        print(String(format: "Nubo encrypted loopback throughput: %.1f Mbps aggregate", aggregateMbps))
        XCTAssertGreaterThan(aggregateMbps, 20, "Encrypted framing should not be a throughput bottleneck")

        await input.cancel()
        await resumed.control.cancel()
        await host.stop()
        hostTask.cancel()
    }
}

private actor MemoryCredentialStore: CredentialStore {
    private var values: [UUID: PairedCredential] = [:]

    func save(_ credential: PairedCredential) async throws { values[credential.peerID] = credential }
    func credential(for peerID: UUID) async throws -> PairedCredential? { values[peerID] }
    func remove(peerID: UUID) async throws { values[peerID] = nil }
}
