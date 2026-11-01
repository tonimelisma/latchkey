import CryptoKit
import Foundation
import Testing

@testable import Latchkey

@Suite struct SignatureTests {
    static let dir = Fixtures.dir.appendingPathComponent("signatures")

    @Test func signatureInputMatchesContract() {
        #expect(
            DeviceIdentity.signatureInput(nonce: "abc", deviceID: "dev_1") == Data("latchkey-agent-v1\nabc\ndev_1".utf8)
        )
    }

    @Test func softwareKeySignsVerifiably() throws {
        let key = SoftwareSigningKey()
        let sig = try key.sign(DeviceIdentity.signatureInput(nonce: "n", deviceID: "d"))
        let der = try #require(Data(base64URL: sig))
        let pub = try P256.Signing.PublicKey(derRepresentation: key.publicKeyDER)
        #expect(
            pub.isValidSignature(
                try P256.Signing.ECDSASignature(derRepresentation: der),
                for: DeviceIdentity.signatureInput(nonce: "n", deviceID: "d")))
        #expect(!sig.contains("="), "base64url without padding")
    }

    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeyRoundTrips() throws {
        let key = try SecureEnclaveSigningKey.create()
        let restored = try SecureEnclaveSigningKey(dataRepresentation: key.dataRepresentation)
        #expect(restored.publicKeyDER == key.publicKeyDER)
        let input = DeviceIdentity.signatureInput(nonce: "n", deviceID: "d")
        let der = try #require(Data(base64URL: try restored.sign(input)))
        let pub = try P256.Signing.PublicKey(derRepresentation: key.publicKeyDER)
        #expect(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: input))
    }

    struct SignatureFixture: Codable {
        var publicKey: String
        var nonce: String
        var deviceID: String
        var signature: String
        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key", nonce, deviceID = "device_id", signature
        }
    }

    /// Writes a Swift-made signature once for the Go tests to verify (relay/agentproto).
    @Test func swiftSignatureFixtureForGo() throws {
        let file = Self.dir.appendingPathComponent("swift.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let key = SoftwareSigningKey()
            let nonce = "q3Jt0b8bK9mH2y1cX7vLZ0aP4sE6dR5fG8hJ1kM2nQo"
            let fixture = SignatureFixture(
                publicKey: key.publicKeyDER.base64URLEncodedString(), nonce: nonce, deviceID: "dev_swift",
                signature: try key.sign(DeviceIdentity.signatureInput(nonce: nonce, deviceID: "dev_swift")))
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(fixture).write(to: file)
        }
        let f = try JSONDecoder().decode(SignatureFixture.self, from: Data(contentsOf: file))
        let pub = try P256.Signing.PublicKey(derRepresentation: try #require(Data(base64URL: f.publicKey)))
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try #require(Data(base64URL: f.signature)))
        #expect(pub.isValidSignature(sig, for: DeviceIdentity.signatureInput(nonce: f.nonce, deviceID: f.deviceID)))
    }

    /// A Go-made signature (written by the Go tests) verifies in Swift.
    @Test func goSignatureVerifies() throws {
        let file = Self.dir.appendingPathComponent("go.json")
        let f = try JSONDecoder().decode(SignatureFixture.self, from: Data(contentsOf: file))
        let pub = try P256.Signing.PublicKey(derRepresentation: try #require(Data(base64URL: f.publicKey)))
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try #require(Data(base64URL: f.signature)))
        #expect(pub.isValidSignature(sig, for: DeviceIdentity.signatureInput(nonce: f.nonce, deviceID: f.deviceID)))
    }
}
