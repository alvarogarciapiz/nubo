import Foundation
import NuboNetworking
import NuboProtocol
import XCTest

final class SecureSessionIntegrationTests: XCTestCase {
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
                case let .message(peerID, .pointer):
                    try await host.send(.pong(777), to: peerID, channel: .input)
                case let .message(peerID, .videoFrame(frame)):
                    try await host.send(.videoFrame(frame), to: peerID, channel: .input)
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
        try await input.send(.pointer(.relativeMotion(.init(dx: 2, dy: -3))))
        let inputResponse = try await input.receive()
        XCTAssertEqual(inputResponse, .pong(777))

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

        let payload = Data(repeating: 0xA5, count: 1_024 * 1_024)
        let throughputStarted = DispatchTime.now().uptimeNanoseconds
        for sequence in 0..<8 {
            let frame = EncodedVideoFrame(
                sequence: UInt64(sequence),
                presentationTimeNanoseconds: UInt64(sequence),
                displayID: .init(rawValue: 1),
                isKeyFrame: sequence == 0,
                bytes: payload
            )
            try await input.send(.videoFrame(frame))
            let echo = try await input.receive()
            XCTAssertEqual(echo, .videoFrame(frame))
        }
        let throughputSeconds = Double(DispatchTime.now().uptimeNanoseconds - throughputStarted) / 1_000_000_000
        let aggregateMbps = Double(payload.count * 8 * 2 * 8) / throughputSeconds / 1_000_000
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
