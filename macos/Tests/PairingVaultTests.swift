import Foundation
import Testing

@testable import Latchkey

/// Stands in for the Keychain and the old settings: tests never touch the real ones, which the
/// installed app shares (.claude/rules/macos.md).
final class MemoryVault: PairingVault, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: Data] = [:]
    var defaults: [String: String] = [:]
    var failWrites = false

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, _ account: String) throws {
        try lock.withLock {
            if failWrites { throw POSIXError(.EACCES) }
            items[account] = data
        }
    }
    func delete(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
    func legacyDefault(_ key: String) -> String? { lock.withLock { defaults[key] } }
    func removeLegacyDefault(_ key: String) { _ = lock.withLock { defaults.removeValue(forKey: key) } }
}

/// The relay address used to be in user defaults, which any program running as the Owner can
/// change without a permission, pointing Latchkey at its own relay (security scan, 2026-10-24).
/// It now lives in the Keychain record with the device ID and the key.
@Suite struct PairingVaultTests {
    static let blob = Data([1, 2, 3])
    let key: @Sendable (Data) throws -> any SigningKey = { data in
        guard data == PairingVaultTests.blob else { throw POSIXError(.EINVAL) }
        return SoftwareSigningKey()
    }

    func oldPairing() -> MemoryVault {
        let v = MemoryVault()
        v.defaults = ["pairedRelayURL": "https://relay.example.com", "pairedDeviceID": "dev_1"]
        v.items = ["device-key": Self.blob]
        return v
    }

    @Test func theOldPairingMovesIntoTheKeychainOnce() throws {
        let v = oldPairing()
        let id = try #require(DeviceIdentity.load(vault: v, makeKey: key))
        #expect(id.relayURL.absoluteString == "https://relay.example.com")
        #expect(id.deviceID == "dev_1")
        #expect(v.defaults.isEmpty, "the old settings are gone")
        #expect(v.items["device-key"] == nil, "the key now lives in the pairing record")
        #expect(v.items["pairing"] != nil)
        #expect(DeviceIdentity.load(vault: v, makeKey: key)?.deviceID == "dev_1", "and loads from there")

        // After Disconnect, settings and a key planted the old way are never taken up again.
        DeviceIdentity.delete(vault: v)
        #expect(DeviceIdentity.load(vault: v, makeKey: key) == nil)
        v.defaults = ["pairedRelayURL": "https://attacker.example", "pairedDeviceID": "dev_x"]
        v.items["device-key"] = Self.blob
        #expect(DeviceIdentity.load(vault: v, makeKey: key) == nil)
    }

    @Test func settingsCannotRedirectAPairedMac() throws {
        let v = MemoryVault()
        try DeviceIdentity.save(
            relayURL: URL(string: "https://relay.example.com")!, deviceID: "dev_1", keyData: Self.blob, vault: v)
        #expect(v.defaults.isEmpty, "nothing is written to user defaults")
        v.defaults = ["pairedRelayURL": "http://127.0.0.1:9999", "pairedDeviceID": "dev_x"]
        let id = try #require(DeviceIdentity.load(vault: v, makeKey: key))
        #expect(id.relayURL.absoluteString == "https://relay.example.com")
        #expect(id.deviceID == "dev_1")
    }

    @Test func onlyHTTPSOrLocalRelaysAreUsed() throws {
        let v = MemoryVault()
        try DeviceIdentity.save(
            relayURL: URL(string: "http://relay.example.com")!, deviceID: "dev_1", keyData: Self.blob, vault: v)
        #expect(DeviceIdentity.load(vault: v, makeKey: key) == nil, "plain http to another host")
        try DeviceIdentity.save(
            relayURL: URL(string: "http://localhost:8080")!, deviceID: "dev_1", keyData: Self.blob, vault: v)
        #expect(DeviceIdentity.load(vault: v, makeKey: key)?.relayURL.absoluteString == "http://localhost:8080")
    }

    @Test func aFailedMoveKeepsTheOldPairing() throws {
        let v = oldPairing()
        v.failWrites = true
        #expect(DeviceIdentity.load(vault: v, makeKey: key)?.deviceID == "dev_1", "still works this time")
        #expect(v.defaults.count == 2 && v.items["device-key"] != nil, "nothing was removed")
        v.failWrites = false
        #expect(DeviceIdentity.load(vault: v, makeKey: key)?.deviceID == "dev_1")
        #expect(v.defaults.isEmpty && v.items["pairing"] != nil, "moved on the next start")
    }

    @Test func missingPartsAreNamed() {
        #expect(DeviceIdentity.missing(vault: MemoryVault()).contains("pairing"))
    }
}
