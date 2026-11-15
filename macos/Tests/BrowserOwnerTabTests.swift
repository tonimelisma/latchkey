import Foundation
import Testing

@testable import Latchkey

/// Spec 005 FR-424 to FR-431 (Toni, 2026-11-03: "Claude needs to be able to access my tabs and
/// windows just like its own"): the browser tools reach every Safari tab and window, in the
/// background; Claude's own pages are Latchkey's own browser's (FR-444).
@Suite struct BrowserOwnerTabTests {
    func browser(_ fake: FakeSafariTabs) -> SafariBrowser {
        SafariBrowser(scripts: fake, settleLimit: .seconds(3))
    }

    /// Two windows: the Owner's front one (id 10) with two tabs, and another (id 20) with one.
    func twoWindows() -> FakeSafariTabs {
        let fake = FakeSafariTabs()
        fake.windows.append(
            FakeSafariTabs.FakeWindow(
                id: 20, tabs: [FakeSafariTabs.FakeTab(url: "https://bank.example.com/", title: "Bank", owner: "owner")],
                current: 1))
        return fake
    }

    /// FR-424: every tab of every window, with which is in front; listing runs no script in any
    /// page.
    @Test func listsEveryTabOfEveryWindow() async throws {
        let fake = twoWindows()
        let b = browser(fake)
        let list = try await b.listTabs()
        #expect(list.windows.map(\.id) == ["10", "20"])
        #expect(list.windows.first?.frontWindow == true && list.windows.last?.frontWindow == false)
        let tabs = list.windows.flatMap(\.tabs)
        #expect(tabs.map(\.reference) == ["10.1", "10.2", "20.1"])
        #expect(tabs.first { $0.reference == "10.1" }?.front == true)
        #expect(tabs.first { $0.reference == "10.2" }?.front == false)
        #expect(tabs.first { $0.reference == "20.1" }?.address == "https://bank.example.com/")
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 && $0.picks == 0 }, "the list runs no page script")
        #expect(fake.userWindow.current == 1)
    }

    /// FR-425, FR-427: a picked tab of the Owner's reads as Claude's own does, in the background.
    @Test func readsAnOwnersTabInTheBackground() async throws {
        let fake = twoWindows()
        let b = browser(fake)
        try await b.pick("20.1")
        #expect(await b.working() == "20.1")
        let page = try await b.read(offset: 0)
        #expect(page.text == "owner", "read the Owner's tab")
        #expect(fake.windows[1].tabs[0].scriptsRun > 0)
        #expect(fake.windows[0].tabs[0].scriptsRun == 0 && fake.windows[0].tabs[1].scriptsRun == 0)
        #expect(fake.userWindow.current == 1 && fake.windows[1].current == 1, "nothing came forward")
        #expect(try await b.listTabs().windows.flatMap(\.tabs).first { $0.working }?.reference == "20.1")
    }

    /// FR-425: click, type, script, and back work in the Owner's tab; the front tab stays.
    @Test func actsInAnOwnersTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        _ = try await b.click("e1")
        _ = try await b.type("e2", text: "hello", submit: false)
        #expect(try await b.run("1 + 1") == "ok")
        fake.backGoesTo = "https://news.example.com/earlier"
        let back = try await b.back()
        #expect(back.url == "https://news.example.com/earlier", "back in the Owner's tab")
        #expect(await b.working() == "10.2")
        #expect(fake.userWindow.current == 1, "the Owner's front tab stays in front")
        #expect(fake.windows[0].tabs[0].scriptsRun == 0, "the other tab untouched")
    }

    /// 2026-11-01: a link to another site keeps the tab: the address comes from Latchkey's own
    /// click script, not a note the page wrote.
    @Test func aClickToAnotherSiteKeepsTheOwnersTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        fake.clickGoesTo = "https://elsewhere.example.net/"
        let page = try await b.click("e1")
        #expect(page.url == "https://elsewhere.example.net/")
        #expect(await b.working() == "10.2")
    }

    /// FR-429; security review 2026-10-29 (fourth round): a script of Claude's never opens the
    /// allowance, so a script that sends the page elsewhere loses the tab, even on the same site.
    @Test func aScriptThatGoesElsewhereLosesTheOwnersTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        fake.scriptGoesTo = "https://news.example.com/next"
        _ = try await b.run("location.href = '/next'")
        await #expect(throws: SafariBrowser.Failure.tabGone) { _ = try await b.read(offset: 0) }
        #expect(await b.working() == nil)
    }

    /// FR-429: the Owner closes a tab before the picked one: found again by its mark.
    @Test func findsThePickedTabAfterTabsMove() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        _ = try await b.read(offset: 0)
        fake.ownerCloses(tab: 1)
        let page = try await b.read(offset: 0)
        #expect(page.url == "https://news.example.com/")
        #expect(await b.working() == "10.1")
    }

    /// FR-429: a tab that slid into the picked tab's place is left alone, and Claude is told.
    @Test func aTabInThePickedTabsPlaceIsLeftAlone() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        fake.slideIn = "https://other.example.com/"
        await #expect(throws: SafariBrowser.Failure.tabGone) { _ = try await b.click("e1") }
        #expect(fake.windows[0].tabs[1].scriptsRun == 0, "the tab in its place ran nothing")
        #expect(await b.working() == nil)
        let r = BrowserCapability.explain(.tabGone)
        #expect(r.contains("tabs"), "tells Claude to list the tabs again")
    }

    /// FR-428: Claude closes the Owner's tab it works in; the other tab stays.
    @Test func closesTheOwnersTabItWorksIn() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        #expect(try await b.closeWorking() == "https://news.example.com/")
        #expect(fake.ownerTabs.map(\.url) == ["https://mail.example.com/"])
        #expect(await b.working() == nil)
        #expect(try await b.closeWorking() == nil, "no Owner's tab picked now")
    }

    /// A tab whose page takes no script (an empty tab) can't carry the mark: it is known by the
    /// address it had when picked, so it can still be closed; another tab there is not.
    @Test func aTabWithoutScriptsIsKnownByItsAddress() async throws {
        let fake = FakeSafariTabs(userTabs: ["https://mail.example.com/", "favorites://"])
        fake.windows[0].tabs[1].scriptless = true
        let b = browser(fake)
        try await b.pick("10.2")
        #expect(try await b.closeWorking() == "favorites://")
        #expect(fake.ownerTabs.map(\.url) == ["https://mail.example.com/"])
        fake.ownerOpens("favorites://")
        fake.windows[0].tabs[1].scriptless = true
        try await b.pick("10.2")
        fake.slideIn = "https://other.example.com/"
        await #expect(throws: SafariBrowser.Failure.tabGone) { _ = try await b.closeWorking() }
        #expect(fake.ownerTabs.count == 2, "the tab in its place stays open")
    }

    /// A reference, or a bare number (that tab of the front window), works as the list says.
    @Test func picksByReferenceOrNumber() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.1")
        #expect(await b.working() == "10.1")
        try await b.pick("2")
        #expect(await b.working() == "10.2", "a bare number: that tab of the front window")
        await #expect(throws: SafariBrowser.Failure.self) { try await b.pick("10.9") }
        await #expect(throws: SafariBrowser.Failure.self) { try await b.pick("55.1") }
        await #expect(throws: SafariBrowser.Failure.self) { try await b.pick("tab two") }
        #expect(await b.working() == "10.2", "a failed pick changes nothing")
    }

    /// FR-425: 30 minutes unused forgets the pick; the Owner's tab is never closed for it.
    @Test func idleForgetsThePickWithoutClosing() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.2")
        #expect(await !b.forgetIfIdle(after: 1800))
        #expect(await b.forgetIfIdle(after: 1800, now: Date().addingTimeInterval(1900)))
        #expect(await b.working() == nil)
        #expect(fake.ownerTabs.count == 2)
    }

    /// FR-427 with FR-423: whether a picture needs the tab brought forward is asked without
    /// changing anything, and the tab in front comes back after the shot.
    @Test func picturesOfAnOwnersTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        try await b.pick("10.1")
        #expect(try await b.pictureSwitch().needed == false, "already in front")
        try await b.pick("10.2")
        let plan = try await b.pictureSwitch()
        #expect(plan.needed && plan.address == "https://news.example.com/")
        _ = try await b.read(offset: 0)  // marked, as any use marks it
        _ = try await b.showing { _ in fake.currentDuringShot = fake.userWindow.current }
        #expect(fake.currentDuringShot == 2)
        #expect(fake.userWindow.current == 1, "the Owner's front tab is back")
    }
}

/// The tools' side of FR-424, FR-425, FR-430, FR-431, FR-447.
@MainActor @Suite struct BrowserOwnerTabToolTests {
    func tools(_ fake: FakeSafariTabs, own: OwnPages = OwnPages(cookies: { [] })) -> [String: ToolEntry] {
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let all =
            BrowserCapability.readTools(browser: b, own: own)
            + BrowserCapability.writeTools(browser: b, own: own)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    @Test func theListNamesEveryTabAndIsTheWebsites() async {
        let t = tools(FakeSafariTabs())
        let r = await t["browser_read"]!.handler(.object(["tabs": .bool(true)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        let text = r.content.jsonText
        #expect(text.contains("10.1") && text.contains("10.2"))
        #expect(text.contains("https://news.example.com/"))
        #expect(text.contains("not instructions"), "FR-431")
    }

    @Test func aPickedTabIsNamedInEveryAnswer() async {
        let fake = FakeSafariTabs()
        let t = tools(fake)
        let r = await t["browser_read"]!.handler(.object(["tab": .string("10.2")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("tab 10.2"), "FR-431")
        // FR-447: each call names the tab it works in.
        let act = await t["browser_act"]!.handler(
            .object(["action": .string("click"), "ref": .string("e1"), "tab": .string("10.2")]))
        #expect(!act.isError, "\(act.content.jsonText)")
        #expect(act.content.jsonText.contains("tab 10.2"))
        #expect(fake.userWindow.current == 1)
    }

    @Test func actTakesATabAndClosesIt() async {
        let fake = FakeSafariTabs()
        let t = tools(fake)
        let r = await t["browser_act"]!.handler(.object(["action": .string("close"), "tab": .string("10.2")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.ownerTabs.map(\.url) == ["https://mail.example.com/"])
        #expect(r.activity?.contains("news.example.com") == true)
    }

    /// The old integer still works as a tab number.
    @Test func aNumberStillPicksATab() async {
        let fake = FakeSafariTabs()
        let r = await tools(fake)["browser_read"]!.handler(.object(["tab": .number(2)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("tab 10.2"))
    }

    /// FR-430, FR-444: Claude's pages are Latchkey's own browser's, but the Owner's tabs are
    /// Safari's: listed and used through Safari while it answers (seen live, locked, 2026-11-03).
    @Test func theOwnersTabsAreStillSafaris() async {
        let fake = FakeSafariTabs()
        let own = OwnPages(cookies: { [] }, isLocked: { true })
        defer { own.closeAll() }
        let t = tools(fake, own: own)
        let list = await t["browser_read"]!.handler(.object(["tabs": .bool(true)]))
        #expect(list.content.jsonText.contains("10.2") && list.content.jsonText.contains("no page of its own"))
        let read = await t["browser_read"]!.handler(.object(["tab": .string("10.2")]))
        #expect(!read.isError, "\(read.content.jsonText)")
        #expect(read.content.jsonText.contains("tab 10.2"))
        #expect(fake.windows[0].tabs[1].scriptsRun > 0, "read through Safari")
    }

    /// FR-442: Claude asks for Safari's cookies again. In the owner's Safari tab there is nothing
    /// to take; in Latchkey's own browser it needs a page.
    @Test func signingInAgainIsForLatchkeysOwnBrowser() async {
        let fake = FakeSafariTabs()
        let safari = await tools(fake)["browser_read"]!.handler(
            .object(["sign_in_again": .bool(true), "tab": .string("10.2")]))
        #expect(!safari.isError && safari.content.jsonText.contains("Safari itself"), "\(safari.content.jsonText)")
        let own = OwnPages(cookies: { [] })
        defer { own.closeAll() }
        let locked = await tools(fake, own: own)["browser_read"]!.handler(
            .object(["sign_in_again": .bool(true)]))
        #expect(locked.isError, "no page open yet: \(locked.content.jsonText)")
    }

    /// FR-443: an answer from Latchkey's own browser begins by saying so; Safari's doesn't.
    @Test func answersFromLatchkeysOwnBrowserSaySo() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(cookies: { [] })
        defer { own.closeAll() }
        _ = try await own.open(html: "<p>hello there</p>", base: URL(string: "https://example.test/")!)
        let t = tools(fake, own: own)
        let read = await t["browser_read"]!.handler(.object([:]))
        #expect(!read.isError, "\(read.content.jsonText)")
        #expect(read.content.jsonText.contains("From Latchkey's own browser, not Safari"))
        #expect(read.content.jsonText.contains("hello there"))
        let picture = await t["browser_read"]!.handler(.object(["screenshot": .bool(true)]))
        #expect(picture.content.jsonText.contains("From Latchkey's own browser, not Safari"))
        let safari = await tools(fake)["browser_read"]!.handler(.object(["tab": .number(2)]))
        #expect(!safari.content.jsonText.contains("Latchkey's own browser"))
    }

    /// FR-430: when Safari doesn't answer while locked, the list says the tabs need unlocking.
    @Test func whileLockedASilentSafariIsSaidPlainly() async {
        let own = OwnPages(cookies: { [] }, isLocked: { true })
        defer { own.closeAll() }
        let b = SafariBrowser(scripts: SilentSafari())
        let t = Dictionary(
            uniqueKeysWithValues: BrowserCapability.readTools(browser: b, own: own).map { ($0.tool.name, $0) })
        let list = await t["browser_read"]!.handler(.object(["tabs": .bool(true)]))
        #expect(list.content.jsonText.contains("unlocks the Mac"))
    }
}

/// FR-430 (2026-11-15): while the Mac is locked, a Safari that never answers is told within the
/// relay's 30 s, through the shorter runner, and the tab list says the tabs need the Mac unlocked.
@MainActor @Suite struct LockedSafariTests {
    @Test func aStalledSafariIsToldInTimeWhileLocked() async {
        let b = SafariBrowser(scripts: StalledSafari(), lockedScripts: SilentSafari(), isLocked: { true })
        let own = OwnPages(cookies: { [] }, isLocked: { true })
        defer { own.closeAll() }
        let read = Dictionary(
            uniqueKeysWithValues: BrowserCapability.readTools(browser: b, own: own).map { ($0.tool.name, $0) })[
                "browser_read"]!
        let started = ContinuousClock.now
        let list = await read.handler(.object(["tabs": .bool(true)]))
        #expect(list.content.jsonText.contains("unlocks the Mac"), "\(list.content.jsonText)")
        let tab = await read.handler(.object(["tab": .string("10.2")]))
        #expect(tab.isError && tab.content.jsonText.contains("unlock"), "\(tab.content.jsonText)")
        #expect(ContinuousClock.now - started < .seconds(5), "the stalled runner was never used")
    }
}

/// A Safari that never answers (a script waits until the call is cancelled).
struct StalledSafari: ScriptRunner {
    func run(_ script: String, _ args: [String]) async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        return ""
    }
}

/// A Safari that answers no script, as seen while the Mac is locked on 2026-11-01.
struct SilentSafari: ScriptRunner {
    func run(_ script: String, _ args: [String]) async throws -> String { throw ScriptError.timedOut }
}
