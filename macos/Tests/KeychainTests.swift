import Foundation
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
}
