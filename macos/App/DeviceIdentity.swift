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

/// The paired identity: relay, device ID, and key, kept together in one Keychain record
/// (FR-051). The relay address and device ID used to be in user defaults, which any program
/// running as the Owner can change without any permission, pointing Latchkey (and its Full Disk
/// Access, Accessibility, and Screen Recording) at a relay of its own (security scan,
/// 2026-10-24). Capability levels stay in user defaults: they only decide what the legitimately
/// paired Claude may use, and the Owner sees them in the menu.
struct DeviceIdentity: Sendable {
    var relayURL: URL
    var deviceID: String
    var key: any SigningKey

    static func signatureInput(nonce: String, deviceID: String) -> Data {
        Data("latchkey-agent-v1\n\(nonce)\n\(deviceID)".utf8)
    }

    private struct Record: Codable {
        var relay: String
        var device: String
        var key: Data
    }

    static let recordAccount = "pairing"
    /// The mark 0.8.4 set after its move; removed with the other leftovers.
    private static let migratedAccount = "pairing-migrated"
    private static let legacyRelay = "pairedRelayURL"
    private static let legacyDevice = "pairedDeviceID"
    private static let legacyKey = "device-key"

    typealias KeyMaker = @Sendable (Data) throws -> any SigningKey
    static let secureEnclaveKey: KeyMaker = { try SecureEnclaveSigningKey(dataRepresentation: $0) }

    /// Only reads the record. A record that is there but can't be read or used is left exactly
    /// as it is (FR-202): the app starts unpaired and tries again at its next launch.
    static func load(vault: any PairingVault = KeychainVault(), makeKey: KeyMaker = secureEnclaveKey)
        -> DeviceIdentity?
    {
        removeOldStylePairing(vault)
        guard let record = record(vault),
            let relay = PairingFlow.normalize(record.relay),
            let key = try? makeKey(record.key)
        else { return nil }
        return DeviceIdentity(relayURL: relay, deviceID: record.device, key: key)
    }

    private static func record(_ vault: any PairingVault) -> Record? {
        vault.read(recordAccount).flatMap { try? PropertyListDecoder().decode(Record.self, from: $0) }
    }

    /// Versions up to 0.8.3 kept the relay and device ID in user defaults, which any program
    /// running as the Owner can change; such a pairing is never used, only removed. (0.8.4 tried
    /// to move it and lost Toni's, the only one; the move is gone with it: security review,
    /// 2026-10-24.)
    private static func removeOldStylePairing(_ vault: any PairingVault) {
        vault.removeLegacyDefault(legacyRelay)
        vault.removeLegacyDefault(legacyDevice)
        vault.delete(legacyKey)
        vault.delete(migratedAccount)
    }

    /// Which parts of a pairing are missing, for the log.
    static func missing(vault: any PairingVault = KeychainVault()) -> String {
        switch vault.lookup(recordAccount) {
        case .absent: return "missing pairing record"
        case .unreadable(let why): return "pairing record present but unreadable: \(why)"
        case .found: break
        }
        guard let r = record(vault) else { return "pairing record present but not understood" }
        if PairingFlow.normalize(r.relay) == nil {
            return "relay address not https"
        }
        return "key unreadable"
    }

    static var missing: String { missing() }

    static func save(relayURL: URL, deviceID: String, key: SecureEnclaveSigningKey) throws {
        try save(relayURL: relayURL, deviceID: deviceID, keyData: key.dataRepresentation)
    }

    static func save(
        relayURL: URL, deviceID: String, keyData: Data, vault: any PairingVault = KeychainVault()
    ) throws {
        let record = Record(relay: relayURL.absoluteString, device: deviceID, key: keyData)
        try vault.write(try PropertyListEncoder().encode(record), recordAccount)
    }

    /// Forgets the pairing (Disconnect, or the relay revoked this Mac).
    static func delete(vault: any PairingVault = KeychainVault()) {
        vault.delete(recordAccount)
        removeOldStylePairing(vault)
    }
}

/// Where the pairing is kept. A protocol so tests use memory: they must never touch real storage
/// (the test app has had its own identity since 0.8.9, `AppIdentity`; the rule stays).
protocol PairingVault: Sendable {
    /// An item of this app's in the Keychain; nil when there's none (or more than one).
    func read(_ account: String) -> Data?
    /// The same look, telling "no item" from "an item that can't be read".
    func lookup(_ account: String) -> StoredItem
    func write(_ data: Data, _ account: String) throws
    func delete(_ account: String)
    /// Removes what versions up to 0.8.3 kept in user defaults.
    func removeLegacyDefault(_ key: String)
}

extension PairingVault {
    func read(_ account: String) -> Data? {
        if case .found(let data) = lookup(account) { data } else { nil }
    }
}

/// The real storage. Under XCTest it changes nothing: while the test app still shared the
/// installed app's Keychain and settings, a test erased the pairing (2026-10-22).
struct KeychainVault: PairingVault {
    private var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func lookup(_ account: String) -> StoredItem { Keychain.lookup(account: account) }

    func write(_ data: Data, _ account: String) throws {
        guard !underTest else { return }
        try Keychain.write(data, account: account)
    }

    func delete(_ account: String) {
        guard !underTest else { return }
        Keychain.delete(account: account)
    }

    func removeLegacyDefault(_ key: String) {
        guard !underTest else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Generic password items of this app in the Owner's login keychain. An item the app creates
/// trusts only this app (the creator) and carries its team's partition, so other programs can't
/// read or change it without the Owner typing the password. Reads never show a prompt
/// (`kSecUseAuthenticationUIFail`): an item this app can't read silently, such as one another
/// program made, is treated as absent. Reads look only in the login keychain, not in keychains
/// another program may add to the search list, and refuse more than one match.
enum Keychain {
    /// This build's own service name: a Debug or test build has its own items and can't reach the
    /// installed app's (`AppIdentity`).
    static let service = AppIdentity.current.keychainService

    /// The login keychain, opened by its path (the default keychain is a setting anyone can change).
    private static var login: SecKeychain? {
        let path = URL.homeDirectory.appending(path: "Library/Keychains/login.keychain-db").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var keychain: SecKeychain?
        return SecKeychainOpen(path, &keychain) == errSecSuccess ? keychain : nil
    }

    private static func query(_ account: String, _ service: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let login { q[kSecMatchSearchList as String] = [login] }
        return q
    }

    /// Tells "no item" from "an item that can't be read" (FR-201): only the first may ever lead
    /// to writing a new one.
    static func lookup(account: String, service: String = service) -> StoredItem {
        // Two steps: the Keychain refuses "all matches, with their data" for passwords
        // (errSecParam), which made every read of 0.8.4–0.8.7 fail. First count the matches
        // without their data, then read the one.
        var count = query(account, service)
        count[kSecReturnAttributes as String] = true
        count[kSecMatchLimit as String] = kSecMatchLimitAll
        count[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?
        let matches = SecItemCopyMatching(count as CFDictionary, &found)
        let number = (found as? [Any])?.count ?? 0
        guard matches == errSecSuccess, number == 1 else {
            return outcome(matches: matches, count: number, read: errSecSuccess, data: nil)
        }

        var q = query(account, service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let read = SecItemCopyMatching(q as CFDictionary, &out)
        return outcome(matches: matches, count: number, read: read, data: out as? Data)
    }

    /// What the two steps' answers mean. Only "not found" on the first step says there is no
    /// item; any other failure leaves the question open, and is answered "there is one".
    static func outcome(matches: OSStatus, count: Int, read: OSStatus, data: Data?) -> StoredItem {
        if matches == errSecItemNotFound { return .absent }
        guard matches == errSecSuccess else { return .unreadable("Keychain error \(matches)") }
        guard count == 1 else { return .unreadable("\(count) items match") }
        guard read == errSecSuccess else { return .unreadable("Keychain error \(read)") }
        guard let data else { return .unreadable("the item has no data") }
        return .found(data)
    }

    /// The item's data; nil when there is none or it can't be read (`lookup` tells which).
    static func read(account: String, service: String = service) -> Data? {
        if case .found(let data) = lookup(account: account, service: service) { data } else { nil }
    }

    /// Saves an item. With `replacing` false an item already there is left alone and the write
    /// fails (errSecDuplicateItem).
    static func write(_ data: Data, account: String, service: String = service, replacing: Bool = true) throws {
        if replacing { delete(account: account, service: service) }
        var q = query(account, service)
        q.removeValue(forKey: kSecMatchSearchList as String)
        if let login { q[kSecUseKeychain as String] = login }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(account: String, service: String = service) {
        SecItemDelete(query(account, service) as CFDictionary)
    }
}
