import CryptoKit
import Foundation
import Security

/// Signs the relay's challenge. The real key lives in the Secure Enclave (plan D6).
protocol SigningKey: Sendable {
    var publicKeyDER: Data { get }
    /// ECDSA P-256 over SHA-256, DER, base64url without padding (agent-protocol.md).
    func sign(_ data: Data) throws -> String
}

struct SoftwareSigningKey: SigningKey {
    let key = P256.Signing.PrivateKey()
    var publicKeyDER: Data { key.publicKey.derRepresentation }
    func sign(_ data: Data) throws -> String {
        try key.signature(for: data).derRepresentation.base64URLEncodedString()
    }
}

struct SecureEnclaveSigningKey: SigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    /// A new key, usable after the first unlock even while the screen is locked (lid closed).
    static func create() throws -> SecureEnclaveSigningKey {
        var error: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)
        else { throw error!.takeRetainedValue() as Error }
        return SecureEnclaveSigningKey(key: try SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
    }

    init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }

    /// Restores a key from its opaque Secure Enclave blob (only this Mac can use it).
    init(dataRepresentation: Data) throws {
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
    }

    var dataRepresentation: Data { key.dataRepresentation }
    var publicKeyDER: Data { key.publicKey.derRepresentation }
    func sign(_ data: Data) throws -> String {
        try key.signature(for: data).derRepresentation.base64URLEncodedString()
    }
}

/// The paired identity: relay, device ID, and key. The key blob is kept in the Keychain
/// (FR-051); the relay URL and device ID in user defaults.
struct DeviceIdentity: Sendable {
    var relayURL: URL
    var deviceID: String
    var key: any SigningKey

    static func signatureInput(nonce: String, deviceID: String) -> Data {
        Data("latchkey-agent-v1\n\(nonce)\n\(deviceID)".utf8)
    }

    private static let defaultsRelay = "pairedRelayURL"
    private static let defaultsDevice = "pairedDeviceID"

    static func load() -> DeviceIdentity? {
        let d = UserDefaults.standard
        guard let relay = d.string(forKey: defaultsRelay).flatMap(URL.init(string:)),
            let device = d.string(forKey: defaultsDevice),
            let blob = Keychain.read(account: Keychain.deviceKeyAccount),
            let key = try? SecureEnclaveSigningKey(dataRepresentation: blob)
        else { return nil }
        return DeviceIdentity(relayURL: relay, deviceID: device, key: key)
    }

    static func save(relayURL: URL, deviceID: String, key: SecureEnclaveSigningKey) throws {
        try Keychain.write(key.dataRepresentation, account: Keychain.deviceKeyAccount)
        UserDefaults.standard.set(relayURL.absoluteString, forKey: defaultsRelay)
        UserDefaults.standard.set(deviceID, forKey: defaultsDevice)
    }

    /// Forgets the pairing (Disconnect, or the relay revoked this Mac).
    static func delete() {
        Keychain.delete(account: Keychain.deviceKeyAccount)
        UserDefaults.standard.removeObject(forKey: defaultsRelay)
        UserDefaults.standard.removeObject(forKey: defaultsDevice)
    }
}

enum Keychain {
    static let service = "net.melisma.latchkey"
    static let deviceKeyAccount = "device-key"

    static func read(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data, account: String) throws {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
