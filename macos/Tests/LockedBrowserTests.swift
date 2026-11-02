import Foundation
import Testing

@testable import Latchkey

/// Spec 005 FR-420: the browser used while the Mac is locked, in a real WebKit view with pages
/// given as text (no network). Its cookies come from Safari's file, which tests never read: the
/// view is made by the test, and only the page-handling is checked here.
@MainActor @Suite struct LockedBrowserTests {
    let base = URL(string: "https://test.example/")!

    @Test func dialogsAreAnsweredAndTold() async throws {
        let b = LockedBrowser()
        defer { b.discard() }
        _ = try await b.open(html: "<p>Hi</p>", base: base)
        #expect(try await b.run("alert('Saved'); 'a'") == "a")
        #expect(try await b.run("confirm('Delete everything?') ? 'yes' : 'no'") == "no", "never a yes")
        #expect(try await b.run("String(prompt('Your name?'))") == "null")
        let told = b.takeDialogs()
        #expect(told.count == 3)
        #expect(told[0].contains("«Saved»") && told[1].contains("answered Cancel") && told[2].contains("gave none"))
        #expect(b.takeDialogs().isEmpty, "told once")
    }

    @Test func identifiesAsSafari() async throws {
        let b = LockedBrowser()
        defer { b.discard() }
        _ = try await b.open(html: "<p>Hi</p>", base: base)
        let agent = try await b.run("navigator.userAgent")
        #expect(agent.contains("Safari/605.1.15") && agent.contains("Version/"))
    }
}
