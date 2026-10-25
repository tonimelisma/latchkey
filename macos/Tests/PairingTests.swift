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

/// Pairing links from outside the app (security review, 2026-10-25).
@Suite struct OutsideLinkTests {
    /// A link can make the app contact the relay it names: one on this Mac without encryption
    /// is accepted only in development builds (FR-054b). The typed-in relay field keeps it.
    @Test func linksToAnUnencryptedLocalRelayAreForDevelopmentBuildsOnly() throws {
        for local in ["http://localhost:8080", "http://127.0.0.1:9"] {
            let link = try #require(URL(string: "latchkey://paired?code=abc&relay=\(local)"))
            let release = try #require(PairingFlow.parse(link, allowLocalHTTP: false))
            #expect(release.code == "abc")
            #expect(release.relay == nil, "\(local) from a link in a release build")
            #expect(PairingFlow.parse(link, allowLocalHTTP: true)?.relay?.absoluteString == local)
            #expect(PairingFlow.normalize(local)?.absoluteString == local, "typed in by the Owner")
        }
        let https = try #require(URL(string: "latchkey://paired?code=abc&relay=https://relay.example.com"))
        #expect(PairingFlow.parse(https, allowLocalHTTP: false)?.relay?.host() == "relay.example.com")
        #expect(
            PairingFlow.normalize("http://relay.example.com", allowLocalHTTP: true) == nil, "never plain http elsewhere"
        )
    }

    /// While one link is being looked up, confirmed, or exchanged, further links are dropped
    /// (FR-054a): no pile of dialogs, no burst of lookups.
    @MainActor @Test func oneLinkAtATime() async {
        let gate = OneAtATime()
        let (stream, release) = AsyncStream.makeStream(of: Void.self)
        let first = Task { @MainActor in
            await gate.run { for await _ in stream { break } }
        }
        for _ in 0..<200 where !gate.busy { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.busy)
        var ran = false
        let second = await gate.run { ran = true }
        #expect(!second, "dropped while the first is in progress")
        #expect(!ran)
        release.yield()
        #expect(await first.value)
        #expect(!gate.busy)
        #expect(await gate.run { ran = true }, "the next link after it is handled")
        #expect(ran)
    }

    /// The relay's address is personal (CLAUDE.md: never in a committed file, threat model
    /// invariant 12): the app's logs carry it only as private data.
    @Test func noRelayAddressIsLoggedPublicly() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../App")
        var offending: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            // A log statement may span lines: look at each interpolation with its privacy.
            for match in text.matches(of: /\\\(([^()]|\([^()]*\))*privacy: \.public\)/) {
                let piece = String(match.output.0)
                if piece.lowercased().contains("relay") || piece.contains("absoluteString") || piece.contains("host") {
                    offending.append("\(file.lastPathComponent): \(piece)")
                }
            }
        }
        #expect(offending.isEmpty, "\(offending)")
    }
}
