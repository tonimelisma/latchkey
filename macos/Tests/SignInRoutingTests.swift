import Foundation
import Testing

@testable import Latchkey

/// Spec 005 FR-455 to FR-459 (Toni, 2026-11-15: "when computer is unlocked, if it's a site that
/// would require my sign-in, use my real browser. otherwise use your own"; and while locked, copy
/// the sign-ins, a sign-out being a side effect). Target rotates its refresh token when a copy
/// uses it, which signed Safari out (Latchkey's log, 19:23:58 that evening).
@MainActor @Suite struct SignInRoutingTests {
    let base = URL(string: "https://test.example/")!

    nonisolated static func cookie(_ domain: String, _ name: String, httpOnly: Bool, days: Double)
        -> SafariCookies.Cookie
    {
        SafariCookies.Cookie(
            domain: domain, name: name, path: "/", value: "v", secure: true, httpOnly: httpOnly,
            expires: Date().addingTimeInterval(days * 86400))
    }

    final class Flag {
        var value: Bool
        init(_ v: Bool) { value = v }
    }

    func tools(_ fake: FakeSafariTabs, own: OwnPages) -> [String: ToolEntry] {
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let all = BrowserCapability.readTools(browser: b, own: own) + BrowserCapability.writeTools(browser: b, own: own)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    /// The page name an answer gave, like p4k2.
    static func pageName(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "\\\"", with: "\"")  // the answer as JSON text
        guard let r = plain.range(of: #"page "p[a-z0-9]{4}""#, options: .regularExpression) else { return nil }
        return String(plain[r].dropFirst(6).dropLast())
    }

    private func cookies(_ pages: OwnPages, _ name: String, until wanted: (String) -> Bool) async throws -> String {
        var seen = ""
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            seen = try await pages.page(name).run("document.cookie")
            if wanted(seen) { break }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return seen
    }

    /// FR-455 (amended 2026-11-24, Toni: "all actions should default to the background browser
    /// actually, unless the user wants to see whatever's going on"): while unlocked, a site the
    /// owner is signed in to in Safari opens in Latchkey's own browser unless Claude asks to show
    /// it; while locked, show_in_safari opens nothing in Safari and says why.
    @Test func pagesOpenInTheBackgroundBrowserUnlessShown() async throws {
        let fake = FakeSafariTabs()
        let locked = Flag(false)
        let own = OwnPages(
            cookies: { [Self.cookie(".shop.example", "session", httpOnly: true, days: 30)] },
            isLocked: { locked.value })
        defer { own.closeAll() }
        let t = tools(fake, own: own)
        let r = await t["browser_look"]!.handler(.object(["url": .string("about:blank")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 2, "no Safari tab")
        #expect(r.content.jsonText.contains("From Latchkey's own browser"), "\(r.content.jsonText)")
        locked.value = true
        let shown = await t["browser_look"]!.handler(
            .object(["url": .string("about:blank"), "show_in_safari": .bool(true)]))
        #expect(!shown.isError, "\(shown.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 2, "locked: no Safari tab")
        #expect(shown.content.jsonText.contains("nobody can watch"), "\(shown.content.jsonText)")
    }

    /// The description says pages open in the background and when to show one in Safari.
    @Test func theDescriptionSaysWhenToShowAPageInSafari() {
        let all = BrowserCapability.readTools(
            browser: SafariBrowser(scripts: FakeSafariTabs()), own: OwnPages(cookies: { [] }))
        let read = all.first { $0.tool.name == "browser_look" }
        let d = read?.tool.description ?? ""
        #expect(d.contains("in the background") && d.contains("show_in_safari") && d.contains("asks to see"))
        #expect(!d.contains("a site the owner is signed in to in Safari opens in a background Safari tab"))
    }

    /// The case of the report: a signed-in site, unlocked, without show_in_safari, never reaches
    /// Safari (the open is refused in a test without network only after the choice is made).
    @Test func aSignedInSiteIsNotMovedToSafariOnItsOwn() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(
            cookies: { [Self.cookie(".shop.example", "session", httpOnly: true, days: 30)] }, isLocked: { false })
        defer { own.closeAll() }
        let look = tools(fake, own: own)["browser_look"]!
        _ = await look.handler(.object(["url": .string("https://www.shop.example/cart")]))
        #expect(fake.windows[0].tabs.count == 2, "no Safari tab of Claude's")
    }

    /// FR-456: while the Mac is unlocked, Claude's pages in Latchkey's own browser take none of
    /// Safari's cookies; while locked they do (FR-441); at unlock the copies are dropped (FR-458).
    @Test func copiesOnlyWhileLockedAndForgottenAtUnlock() async throws {
        let jar = LockedBrowserTests.Jar()
        jar.set(["sid": "one"])
        let locked = Flag(false)
        let pages = OwnPages(cookies: { jar.cookies }, isLocked: { locked.value }, record: { _ in })
        defer { pages.closeAll() }
        let first = try await pages.open(html: "<p>Hi</p>", base: base)
        #expect(try await pages.page(first).run("document.cookie") == "", "unlocked: nothing copied")
        locked.value = true
        let second = try await pages.open(html: "<p>Hi</p>", base: base)
        #expect(try await cookies(pages, second) { $0.contains("sid=one") }.contains("sid=one"), "locked: copied")
        locked.value = false
        await pages.forgetCopiesIfUnlocked()
        let after = try await cookies(pages, second) { !$0.contains("sid=") }
        #expect(!after.contains("sid="), "unlocked again: the copy is gone: \(after)")
    }

    /// FR-455: with show_in_safari, a page opens in a background Safari tab of Claude's; later
    /// calls by its name work there; a url with its name loads in the same tab; close closes it.
    @Test func aShownPageOpensInASafariTabOfClaudesWhileUnlocked() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(
            cookies: { [Self.cookie(".shop.example", "session", httpOnly: true, days: 30)] }, isLocked: { false })
        defer { own.closeAll() }
        let t = tools(fake, own: own)
        let r = await t["browser_look"]!.handler(
            .object(["url": .string("https://www.shop.example/cart"), "show_in_safari": .bool(true)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 3)
        #expect(fake.windows[0].tabs.last?.url == "https://www.shop.example/cart")
        #expect(fake.userWindow.current == 1, "the owner's front tab stays in front")
        let text = r.content.jsonText
        #expect(text.contains("Safari tab of Claude's"), "\(text)")
        let name = try #require(Self.pageName(text), "\(text)")

        let before = fake.windows[0].tabs[2].scriptsRun
        let read = await t["browser_look"]!.handler(.object(["page": .string(name)]))
        #expect(!read.isError, "\(read.content.jsonText)")
        #expect(fake.windows[0].tabs[2].scriptsRun > before, "read in Claude's Safari tab")
        #expect(fake.windows[0].tabs[0].scriptsRun == 0 && fake.windows[0].tabs[1].scriptsRun == 0)
        #expect(own.listing().contains(name))

        let again = await t["browser_look"]!.handler(
            .object(["url": .string("https://www.shop.example/orders"), "page": .string(name)]))
        #expect(!again.isError, "\(again.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 3 && fake.windows[0].tabs[2].url == "https://www.shop.example/orders")

        let closed = await t["browser_act"]!.handler(.object(["action": .string("close"), "page": .string(name)]))
        #expect(!closed.isError, "\(closed.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 2)
        #expect(!own.listing().contains(name))
    }

    /// FR-459: while unlocked, sign_in_again moves a page of Latchkey's own browser into a Safari
    /// tab of Claude's at the same address, under the same name.
    @Test func signingInAgainWhileUnlockedMovesThePageIntoSafari() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(cookies: { [] }, isLocked: { false })
        defer { own.closeAll() }
        let name = try await own.open(html: "<p>Signed out</p>", base: URL(string: "https://www.shop.example/")!)
        let r = await tools(fake, own: own)["browser_look"]!.handler(
            .object(["sign_in_again": .bool(true), "page": .string(name)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.windows[0].tabs.count == 3)
        #expect(fake.windows[0].tabs.last?.url == "https://www.shop.example/")
        #expect(r.content.jsonText.contains("Safari tab of Claude's"))
        #expect(own.safariPage(name) != nil, "the same name, now in Safari")
    }

    /// Spec 013 FR-1374 (Toni, 2026-11-22: Claude decides, "Decide fresh each time"): a page of a
    /// site Latchkey signs in to itself moves into Safari when Claude asks, while unlocked; the
    /// next page of that site opens in Latchkey's own browser again.
    @Test func signingInAgainOnAnOwnSiteMovesThatPageIntoSafari() async throws {
        let fake = FakeSafariTabs()
        let signIns = SignInStore(vault: MemoryVault())
        try signIns.replace(with: [SignInFillTests.ann], at: Date(timeIntervalSince1970: 1_800_000_000))
        let sessions = OwnSessions(signIns: signIns, vault: MemoryVault())
        sessions.on = { true }
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in }, sessions: sessions)
        defer { own.closeAll() }
        let name = try await own.open(html: "<p>Sign in</p>", base: URL(string: "https://a.test/login")!)
        let r = await tools(fake, own: own)["browser_look"]!.handler(
            .object(["sign_in_again": .bool(true), "page": .string(name)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(own.safariPage(name) != nil, "the same name, now in Safari")
        #expect(fake.windows[0].tabs.last?.url == "https://a.test/login")
        _ = await tools(fake, own: own)["browser_look"]!.handler(.object(["url": .string("https://a.test/other")]))
        #expect(fake.windows[0].tabs.count == 3, "nothing remembered: the next page starts in Latchkey's own")
    }
}
