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
    /// Accounts whose item is there but can't be read, as when a Keychain read fails.
    var unreadable: Set<String> = []
    /// Every write and delete, to show what was left alone.
    var changes: [String] = []

    func lookup(_ account: String) -> StoredItem {
        lock.withLock {
            guard let data = items[account] else { return .absent }
            return unreadable.contains(account) ? .unreadable("stand-in failure") : .found(data)
        }
    }
    func write(_ data: Data, _ account: String) throws {
        try lock.withLock {
            if failWrites { throw POSIXError(.EACCES) }
            changes.append("write \(account)")
            items[account] = data
        }
    }
    func delete(_ account: String) {
        lock.withLock {
            changes.append("delete \(account)")
            _ = items.removeValue(forKey: account)
        }
    }
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

    /// Versions up to 0.8.3 kept the relay and device ID in user defaults, which any program
    /// running as the Owner can change. Such a pairing is never used (it moved nowhere: the only
    /// one, Toni's, was lost to 0.8.4's move and paired again), and its leftovers are removed.
    @Test func anOldStylePairingIsNeverUsed() throws {
        let v = oldPairing()
        #expect(DeviceIdentity.load(vault: v, makeKey: key) == nil)
        #expect(v.defaults.isEmpty, "the old settings are removed")
        #expect(v.items["device-key"] == nil, "and the old key")
        #expect(v.items["pairing"] == nil, "nothing was taken from them")
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

    @Test func missingPartsAreNamed() {
        #expect(DeviceIdentity.missing(vault: MemoryVault()).contains("pairing"))
    }
}
