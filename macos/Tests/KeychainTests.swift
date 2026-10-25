import Foundation
import Security
import Testing

@testable import Latchkey

/// The real Keychain calls, against a throwaway service name so the app's own items (the pairing,
/// the activity log's key) are never touched. Until 0.8.7 nothing exercised them: the read asked
/// for all matches with their data, which the Keychain refuses for passwords (errSecParam), so
/// every restart of 0.8.4–0.8.7 found no pairing and made a new activity-log key.
@Suite struct KeychainTests {
    @Test func whatIsWrittenIsReadBack() throws {
        let service = "net.melisma.latchkey.tests.\(UUID().uuidString)"
        defer { Keychain.delete(account: "probe", service: service) }
        #expect(Keychain.read(account: "probe", service: service) == nil, "nothing there yet")

        try Keychain.write(Data("first".utf8), account: "probe", service: service)
        #expect(Keychain.read(account: "probe", service: service) == Data("first".utf8))

        try Keychain.write(Data("second".utf8), account: "probe", service: service)
        #expect(Keychain.read(account: "probe", service: service) == Data("second".utf8), "a write replaces")

        Keychain.delete(account: "probe", service: service)
        #expect(Keychain.read(account: "probe", service: service) == nil)
    }

    /// FR-201: "no item" and "an item" are told apart, and a write that must not replace doesn't.
    @Test func aLookTellsNoItemFromAnItem() throws {
        let service = "net.melisma.latchkey.tests.\(UUID().uuidString)"
        defer { Keychain.delete(account: "probe", service: service) }
        #expect(Keychain.lookup(account: "probe", service: service) == .absent)

        try Keychain.write(Data("first".utf8), account: "probe", service: service, replacing: false)
        #expect(Keychain.lookup(account: "probe", service: service) == .found(Data("first".utf8)))

        #expect(throws: (any Error).self, "an item already there is not replaced") {
            try Keychain.write(Data("second".utf8), account: "probe", service: service, replacing: false)
        }
        #expect(Keychain.lookup(account: "probe", service: service) == .found(Data("first".utf8)))
    }

    /// What the Keychain's answers mean (FR-201). Only "not found" on the first step means there
    /// is no item; every other failure means there is one that can't be read. (Not tried against
    /// the real Keychain: an item this app may not read makes macOS ask the Owner on screen.)
    @Test func onlyNotFoundMeansNoItem() {
        let data = Data("x".utf8)
        #expect(Keychain.outcome(matches: errSecItemNotFound, count: 0, read: errSecSuccess, data: nil) == .absent)
        #expect(Keychain.outcome(matches: errSecSuccess, count: 1, read: errSecSuccess, data: data) == .found(data))
        #expect(
            Keychain.outcome(matches: errSecSuccess, count: 1, read: errSecInteractionNotAllowed, data: nil)
                == .unreadable("Keychain error -25308"), "another program's item, or a locked keychain")
        #expect(
            Keychain.outcome(matches: errSecSuccess, count: 1, read: errSecItemNotFound, data: nil)
                == .unreadable("Keychain error -25300"), "counted, then gone: not a reason to write")
        #expect(
            Keychain.outcome(matches: errSecSuccess, count: 1, read: errSecSuccess, data: nil)
                == .unreadable("the item has no data"))
        #expect(
            Keychain.outcome(matches: errSecSuccess, count: 2, read: errSecSuccess, data: data)
                == .unreadable("2 items match"))
        #expect(
            Keychain.outcome(matches: errSecParam, count: 0, read: errSecSuccess, data: nil)
                == .unreadable("Keychain error -50"), "the read bug of 0.8.4 to 0.8.7")
        #expect(
            Keychain.outcome(matches: errSecInteractionNotAllowed, count: 0, read: errSecSuccess, data: nil)
                == .unreadable("Keychain error -25308"))
    }
}
