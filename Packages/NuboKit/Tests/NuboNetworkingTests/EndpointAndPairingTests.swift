import NuboNetworking
import XCTest

final class EndpointAndPairingTests: XCTestCase {
    func testPairingQRIsStrictAndNeverAnEndpoint() {
        XCTAssertEqual(PairingCode.qrPayload(for: "012345"), "nubo-pair:v1:012345")
        XCTAssertEqual(PairingCode.code(fromQR: "nubo-pair:v1:012345"), "012345")
        XCTAssertNil(PairingCode.code(fromQR: "https://untrusted.example/012345"))
        XCTAssertNil(PairingCode.code(fromQR: "nubo-pair:v1:012345extra"))
        XCTAssertNil(PairingCode.code(fromQR: "nubo-pair:v2:012345"))
        XCTAssertNil(PairingCode.qrPayload(for: "12345"))
        XCTAssertFalse(PairingCode.matches(PairingCode.code(fromQR: "nubo-pair:v1:111111") ?? "", expected: "222222"))
    }
    func testTypedPairingCodeRequiresAllSixASCIIDigits() {
        XCTAssertTrue(PairingCode.matches("012345", expected: "012345"))
        XCTAssertFalse(PairingCode.matches("12345", expected: "012345"))
        XCTAssertFalse(PairingCode.matches("012346", expected: "012345"))
        XCTAssertFalse(PairingCode.matches("０１２３４５", expected: "012345"))
        XCTAssertFalse(PairingCode.matches("012345 ", expected: "012345"))
    }
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

    func testCommitmentsBindBothIdentitiesToKeyAgreement() throws {
        let a = PairingChallenge()
        let b = PairingChallenge()
        let aID = UUID()
        let aCommitment = try PairingKeyAgreement.commitment(for: .init(deviceID: aID, deviceName: "iPad", challenge: a))
        let bCommitment = try PairingKeyAgreement.commitment(for: .init(deviceID: UUID(), deviceName: "Mac", challenge: b))
        let changed = try PairingKeyAgreement.commitment(for: .init(deviceID: aID, deviceName: "Impersonated", challenge: a))
        XCTAssertNotEqual(aCommitment, changed)
        let first = try PairingKeyAgreement.deriveSecret(local: a, peerPublicKey: b.publicKey, peerNonce: b.nonce, localCommitment: aCommitment, peerCommitment: bCommitment)
        let second = try PairingKeyAgreement.deriveSecret(local: b, peerPublicKey: a.publicKey, peerNonce: a.nonce, localCommitment: bCommitment, peerCommitment: aCommitment)
        let tampered = try PairingKeyAgreement.deriveSecret(local: b, peerPublicKey: a.publicKey, peerNonce: a.nonce, localCommitment: bCommitment, peerCommitment: changed)
        XCTAssertEqual(first.secret, second.secret)
        XCTAssertEqual(first.confirmationCode, second.confirmationCode)
        XCTAssertNotEqual(first.secret, tampered.secret)
    }

    func testAuthenticationProofRejectsDifferentNonce() {
        let secret = Data(repeating: 7, count: 32)
        let id = UUID()
        let nonce = Data(repeating: 1, count: 32)
        let proof = PeerAuthentication.clientProof(secret: secret, deviceID: id, channel: .control, nonce: nonce)
        let wrong = PeerAuthentication.clientProof(secret: secret, deviceID: id, channel: .control, nonce: Data(repeating: 2, count: 32))
        let wrongChannel = PeerAuthentication.clientProof(secret: secret, deviceID: id, channel: .input, nonce: nonce)
        XCTAssertTrue(PeerAuthentication.verify(proof, matches: proof))
        XCTAssertFalse(PeerAuthentication.verify(proof, matches: wrong))
        XCTAssertFalse(PeerAuthentication.verify(proof, matches: wrongChannel))
    }
}
