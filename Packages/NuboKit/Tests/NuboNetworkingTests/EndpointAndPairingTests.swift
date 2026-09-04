import NuboNetworking
import XCTest

final class EndpointAndPairingTests: XCTestCase {
    func testManualEndpointAcceptsHostname() throws {
        let endpoint = try ManualEndpoint(host: " macbook.tailnet.ts.net ", port: 49_832)
        XCTAssertEqual(endpoint.host, "macbook.tailnet.ts.net")
        XCTAssertEqual(endpoint.endpoint, .manual(host: "macbook.tailnet.ts.net", port: 49_832))
    }

    func testManualEndpointRejectsInvalidValues() {
        XCTAssertThrowsError(try ManualEndpoint(host: "", port: 49_832))
        XCTAssertThrowsError(try ManualEndpoint(host: "mac.local", port: 0))
        XCTAssertThrowsError(try ManualEndpoint(host: "mac.local", port: 70_000))
    }

    func testPairingAgreementProducesSameSecretAndCode() throws {
        let a = PairingChallenge()
        let b = PairingChallenge()
        let resultA = try PairingKeyAgreement.deriveSecret(local: a, peerPublicKey: b.publicKey, peerNonce: b.nonce)
        let resultB = try PairingKeyAgreement.deriveSecret(local: b, peerPublicKey: a.publicKey, peerNonce: a.nonce)
        XCTAssertEqual(resultA.secret, resultB.secret)
        XCTAssertEqual(resultA.confirmationCode, resultB.confirmationCode)
        XCTAssertEqual(resultA.confirmationCode.count, 6)
    }

    func testAuthenticationProofRejectsDifferentNonce() {
        let secret = Data(repeating: 7, count: 32)
        let id = UUID()
        let nonce = Data(repeating: 1, count: 32)
        let proof = PeerAuthentication.clientProof(secret: secret, deviceID: id, channel: .control, nonce: nonce)
        let wrong = PeerAuthentication.clientProof(secret: secret, deviceID: id, channel: .control, nonce: Data(repeating: 2, count: 32))
        XCTAssertTrue(PeerAuthentication.verify(proof, matches: proof))
        XCTAssertFalse(PeerAuthentication.verify(proof, matches: wrong))
    }
}
