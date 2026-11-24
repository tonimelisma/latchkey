import Foundation
import Testing

@testable import Latchkey

/// Regression cases of the browser (macos/scripts/state-check/cases.json, regressions-browser),
/// batch B. Real WebKit pages given as text, and the stand-in Safari of BrowserTabTests.
@MainActor @Suite struct RegressionBrowserBTests {
    func tools(_ fake: FakeSafariTabs, own: OwnPages) -> [String: ToolEntry] {
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let all = BrowserCapability.readTools(browser: b, own: own) + BrowserCapability.writeTools(browser: b, own: own)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    /// regressions.browser_click_changed_nothing_said (Gmail, 2026-11-16): a click that did nothing
    /// was answered as a plain success, so Claude retried blind. browser_act click on a link the
    /// page cancels says nothing changed and what to try next; a click that changes the page
    /// doesn't.
    @Test func aClickThatChangesNothingSaysSoAndWhatToTryNext() async throws {
        let own = OwnPages(cookies: { [] }, isLocked: { false })
        defer { own.closeAll() }
        let t = tools(FakeSafariTabs(), own: own)
        let name = try await own.open(
            html: """
                <title>Inert</title><a href="#" id="lki" onclick="return false">Latchkey inert</a>
                <button onclick="document.getElementById('out').textContent = 'done'">Latchkey live</button>
                <p id="out"></p>
                """, base: URL(string: "https://test.example/")!)
        let page = try await own.page(name).read(offset: 0)
        let inert = try #require(page.elements.first { $0.label.contains("Latchkey inert") }, "\(page.elements)")
        let live = try #require(page.elements.first { $0.label.contains("Latchkey live") })

        let r = await t["browser_act"]!.handler(
            .object(["action": .string("click"), "ref": .string(inert.ref), "page": .string(name)]))
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("Nothing on the page changed after the click"), "\(r.plainText)")
        #expect(r.plainText.contains("Try key Enter or Space"), "names what to try next: \(r.plainText)")

        let ok = await t["browser_act"]!.handler(
            .object(["action": .string("click"), "ref": .string(live.ref), "page": .string(name)]))
        #expect(!ok.isError, "\(ok.plainText)")
        #expect(ok.plainText.contains("done"), "\(ok.plainText)")
        #expect(!ok.plainText.contains("Nothing on the page changed"), "\(ok.plainText)")
    }

    /// regressions.browser_tabs_left_open (Toni, 2026-11-21: "you've left all the browser tabs
    /// open"): a page whose Safari tab is gone couldn't be closed and stayed listed for ever. Now
    /// closing it says so, and the page is forgotten. (Closing Claude's tabs at quit:
    /// BrowserOwnerTabTests.claudesSafariTabsCloseAtQuit.)
    @Test func aPageWhoseSafariTabIsGoneIsForgottenWhenClosed() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(
            cookies: { [SignInRoutingTests.cookie(".shop.example", "session", httpOnly: true, days: 30)] },
            isLocked: { false })
        defer { own.closeAll() }
        let t = tools(fake, own: own)
        let opened = await t["browser_look"]!.handler(
            .object(["url": .string("https://www.shop.example/cart"), "show_in_safari": .bool(true)]))
        #expect(!opened.isError, "\(opened.content.jsonText)")
        let name = try #require(SignInRoutingTests.pageName(opened.content.jsonText), "\(opened.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 3 && own.listing().contains(name))

        fake.ownerCloses(tab: 3)  // Claude's tab is closed in Safari itself
        let closed = await t["browser_act"]!.handler(.object(["action": .string("close"), "page": .string(name)]))
        #expect(closed.plainText.contains("forgot the page"), "\(closed.plainText)")
        #expect(!own.listing().contains(name), "no longer listed")
        #expect(fake.ownerTabs.map(\.url) == ["https://mail.example.com/", "https://news.example.com/"])
    }
}
