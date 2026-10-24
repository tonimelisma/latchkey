import Foundation
import Testing

@testable import Latchkey

/// A pairing link that arrives other than through the app's own sign-in window connects only
/// after the Owner confirms a dialog naming the relay and the account's email (FR-054).
@Suite struct PairingConfirmationTests {
    let relay = URL(string: "https://relay.example.com")!

    /// The link controls the relay; the email is only what that relay claims. So the title names
    /// the relay, and the email is attributed to it.
    @Test func leadsWithTheRelayAndAttributesTheEmail() {
        let c = PairingConfirmation(relay: relay, email: "owner@example.com", current: nil, hosted: relay)
        #expect(c.canConnect)
        #expect(c.title == "Connect this Mac to relay.example.com?")
        #expect(c.message.hasPrefix("relay.example.com says this is the account owner@example.com."))
        #expect(!c.message.contains("replaces"), "nothing to replace")
        #expect(!c.message.contains("different relay"), "the relay this app suggests")
    }

    @Test func saysItReplacesTheCurrentPairingOnAnotherRelay() {
        let c = PairingConfirmation(
            relay: relay, email: "owner@example.com", current: URL(string: "https://old.example.org")!, hosted: nil)
        #expect(c.canConnect)
        #expect(c.message.contains("This replaces this Mac’s current connection to old.example.org."))
        #expect(c.message.contains("This is a different relay from the one this Mac uses now (old.example.org)."))
    }

    @Test func sameRelayReplacementSaysNothingAboutADifferentRelay() {
        let c = PairingConfirmation(relay: relay, email: "owner@example.com", current: relay, hosted: nil)
        #expect(c.message.contains("replaces"))
        #expect(!c.message.contains("different relay"))
    }

    @Test func unpairedOnAnotherRelayThanTheSuggestedOne() {
        let c = PairingConfirmation(
            relay: relay, email: "owner@example.com", current: nil, hosted: URL(string: "https://hosted.example.net")!)
        #expect(
            c.message.contains("This is a different relay from the one this app suggests (hosted.example.net)."))
    }

    @Test func anExpiredLinkOffersNoConnect() {
        let c = PairingConfirmation(relay: relay, email: nil, current: nil, hosted: nil)
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
