import Foundation
import Testing

@testable import Latchkey

/// A pairing link that arrives other than through the app's own sign-in window connects only
/// after the Owner confirms a dialog naming the relay and the account's email (FR-054).
@Suite struct PairingConfirmationTests {
    let relay = URL(string: "https://relay.example.com")!

    @Test func namesTheAccountAndTheRelay() {
        let c = PairingConfirmation(relay: relay, email: "owner@example.com", current: nil)
        #expect(c.canConnect)
        #expect(c.title == "Connect this Mac to owner@example.com’s account?")
        #expect(c.message.contains("relay.example.com"))
        #expect(!c.message.contains("replaces"), "nothing to replace")
    }

    @Test func saysItReplacesTheCurrentPairing() {
        let c = PairingConfirmation(
            relay: relay, email: "owner@example.com", current: URL(string: "https://old.example.org")!)
        #expect(c.canConnect)
        #expect(c.message.contains("replaces"))
        #expect(c.message.contains("old.example.org"))
    }

    @Test func anExpiredLinkOffersNoConnect() {
        let c = PairingConfirmation(relay: relay, email: nil, current: nil)
        #expect(!c.canConnect, "no Connect without knowing whose account it is")
        #expect(c.title.contains("expired"))
        #expect(c.message.contains("Connect to a Relay…"))
    }

    @Test func refusesAnEmailThatCouldMisleadTheDialog() {
        #expect(PairingFlow.cleanEmail(" owner@example.com ") == "owner@example.com")
        #expect(PairingFlow.cleanEmail("owner@example.com\nYour bank") == nil, "no line breaks")
        #expect(PairingFlow.cleanEmail("not an email") == nil)
        #expect(PairingFlow.cleanEmail(String(repeating: "a", count: 300) + "@example.com") == nil)
        #expect(PairingFlow.cleanEmail("") == nil)
    }

    @Test func lookupFailsWhenTheRelayIsUnreachable() async {
        await #expect(throws: PairingError.self) {
            try await PairingFlow.preview(relay: URL(string: "http://127.0.0.1:9")!, code: "abc")
        }
    }
}
