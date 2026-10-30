import Foundation
import Testing

@testable import Latchkey

/// Plays Safari with windows and tabs, for Claude's page in a tab of the Owner's window (spec 005
/// FR-412 to FR-418). Answers the tab scripts the way Safari would, and records which tabs ran
/// which script, so a test can tell that the Owner's tabs were never read or changed (FR-403).
final class FakeSafariTabs: ScriptRunner, @unchecked Sendable {
    struct FakeTab {
        var url: String
        var title: String
        var owner: String
        /// What the page holds after Latchkey marked it; a new document loses it.
        var mark: String?
        /// Scripts other than the yes/no check that ran in this tab.
        var scriptsRun = 0
        /// Times the yes/no check ran in this tab.
        var checks = 0
    }

    struct FakeWindow {
        var id: Int
        var tabs: [FakeTab]
        var current: Int
    }

    private let lock = NSLock()
    var windows: [FakeWindow]
    private(set) var calls: [(script: String, args: [String])] = []
    /// Changes with each page load, like performance.timeOrigin.
    private(set) var loads = 0
    /// The current tab while the screenshot ran.
    var currentDuringShot: Int?
    /// Set to an address: right before the next script that acts on Claude's tab (after
    /// Latchkey found it), the Owner closes Claude's tab and opens one at that address in its
    /// place, so the tab count stays the same.
    var slideIn: String?
    /// Set to an address: the next click in Claude's tab goes to that page.
    var clickGoesTo: String?

    init(userTabs: [String] = ["https://mail.example.com/", "https://news.example.com/"]) {
        windows =
            userTabs.isEmpty
            ? []
            : [
                FakeWindow(
                    id: 10, tabs: userTabs.map { FakeTab(url: $0, title: "Owner's", owner: "owner") }, current: 1)
            ]
    }

    var userWindow: FakeWindow { windows[0] }
    var ownerTabs: [FakeTab] { windows.flatMap(\.tabs).filter { $0.owner == "owner" } }
    var claudeTabs: [FakeTab] { windows.flatMap(\.tabs).filter { $0.owner == "claude" } }
    var scripts: [String] { lock.withLock { calls.map(\.script) } }

    private func window(_ id: String) throws -> Int {
        guard let w = windows.firstIndex(where: { String($0.id) == id }) else {
            throw ScriptError.failed("execution error: LATCHKEY_NO_WINDOW (-2700)")
        }
        return w
    }

    private func marked(_ tab: FakeTab, _ checkJS: String) -> Bool {
        tab.mark.map { checkJS.contains("'\($0)'") } ?? false
    }

    /// Like the tab scripts' guard: the count is the same, and the tab carries Claude's mark or
    /// is loading an address Claude just loaded (args: window, index, count, check, addresses).
    private func guarded(_ args: [String]) throws -> (Int, Int) {
        let w = try window(args[0])
        let i = Int(args[1])! - 1
        if let address = slideIn, i < windows[w].tabs.count {
            slideIn = nil
            windows[w].tabs[i] = FakeTab(url: address, title: "Owner's", owner: "owner")
        }
        guard windows[w].tabs.count == Int(args[2]) else {
            throw ScriptError.failed("execution error: LATCHKEY_MOVED (-2700)")
        }
        windows[w].tabs[i].checks += 1
        let loading = !args[4].isEmpty && args[4].split(separator: "\n").contains { $0 == windows[w].tabs[i].url }
        guard marked(windows[w].tabs[i], args[3]) || loading else {
            throw ScriptError.failed("execution error: LATCHKEY_MOVED (-2700)")
        }
        return (w, i)
    }

    private static func token(in js: String) -> String? {
        guard let r = js.range(of: #"__latchkeyTab', \{ value: '([0-9a-f]+)'"#, options: .regularExpression) else {
            return nil
        }
        let found = js[r]
        return found.split(separator: "'").dropFirst(2).first.map(String.init)
    }

    func run(_ script: String, _ args: [String]) async throws -> String {
        try lock.withLock {
            calls.append((script, args))
            switch script {
            case SafariBrowser.Script.tabNew:
                loads += 1
                let tab = FakeTab(url: args[0], title: "Claude's", owner: "claude")
                if windows.isEmpty {
                    windows.append(FakeWindow(id: 90, tabs: [tab], current: 1))
                    return "90\t1\t1"
                }
                windows[0].tabs.append(tab)
                let n = windows[0].tabs.count
                return "\(windows[0].id)\t\(n)\t\(n)"
            case SafariBrowser.Script.tabSurvey:
                let w = try window(args[0])
                let idx = Int(args[1])!
                let expected = args[4].split(separator: "\n").map(String.init)
                var out = "\(windows[w].tabs.count)\n"
                for i in windows[w].tabs.indices {
                    let same = windows[w].tabs[i].url == args[2]
                    var isMarked = false
                    var loading = false
                    if i + 1 == idx || same {
                        windows[w].tabs[i].checks += 1
                        isMarked = marked(windows[w].tabs[i], args[3])
                    }
                    if i + 1 == idx { loading = expected.contains(windows[w].tabs[i].url) }
                    out += "\(i + 1)\t\(same)\t\(isMarked)\t\(loading)\n"
                }
                return out
            case SafariBrowser.Script.tabJavaScript:
                let (w, i) = try guarded(args)
                let js = args[5]
                windows[w].tabs[i].scriptsRun += 1
                if let token = Self.token(in: js) { windows[w].tabs[i].mark = token }
                var destination = ""
                if js.contains("e.click()"), let next = clickGoesTo {
                    clickGoesTo = nil
                    destination = next
                }
                let tab = windows[w].tabs[i]
                if !destination.isEmpty {
                    loads += 1
                    windows[w].tabs[i].url = destination
                    windows[w].tabs[i].mark = nil
                }
                let answer: String
                if js.contains("timeOrigin") {
                    answer = "\(loads)|complete|\(tab.url)"
                } else if js.contains("latchkeyRead") {
                    answer =
                        #"{"title":"Claude's page","url":"\#(tab.url)","total":5,"text":"\#(tab.owner)","elements":[]}"#
                } else if js.contains("document.title") {
                    answer = "\(tab.title)\t\(tab.url)"
                } else {
                    answer = "ok"
                }
                return tab.url + "\n" + destination + "\n" + answer
            case SafariBrowser.Script.tabLoad:
                let (w, i) = try guarded(args)
                loads += 1
                windows[w].tabs[i].url = args[5]
                windows[w].tabs[i].mark = nil
                windows[w].tabs[i].scriptsRun += 1
                return ""
            case SafariBrowser.Script.tabShow:
                let (w, i) = try guarded(args)
                let previous = windows[w].current
                windows[w].current = i + 1
                return "\(previous)\t\(windows[w].tabs[i].title)"
            case SafariBrowser.Script.tabRestore:
                let w = try window(args[0])
                let i = Int(args[1])!
                if windows[w].current == i, i <= windows[w].tabs.count, marked(windows[w].tabs[i - 1], args[3]) {
                    windows[w].current = Int(args[2])!
                }
                return ""
            case SafariBrowser.Script.tabClose:
                let (w, i) = try guarded(args)
                windows[w].tabs.remove(at: i)
                if windows[w].current > windows[w].tabs.count { windows[w].current = windows[w].tabs.count }
                if windows[w].tabs.isEmpty { windows.remove(at: w) }
                return ""
            case SafariBrowser.Script.close:
                windows.removeAll { String($0.id) == args[0] }
                return ""
            default:
                if script.contains("make new document") {
                    loads += 1
                    windows.append(
                        FakeWindow(
                            id: 77, tabs: [FakeTab(url: args[0], title: "Claude's", owner: "claude-window")],
                            current: 1))
                    return "77"
                }
                if script.contains("do JavaScript") {
                    let js = args.last ?? ""
                    if js.contains("timeOrigin") { return "\(loads)|complete|https://w.example.com/" }
                    if js.contains("latchkeyRead") {
                        return #"{"title":"W","url":"https://w.example.com/","total":1,"text":"w","elements":[]}"#
                    }
                    return "ok"
                }
                return ""
            }
        }
    }

    /// The Owner closes a tab (1-based), as in Safari.
    func ownerCloses(tab: Int) {
        lock.withLock {
            windows[0].tabs.remove(at: tab - 1)
            if windows[0].current > windows[0].tabs.count { windows[0].current = windows[0].tabs.count }
        }
    }

    /// The Owner opens a tab at the end.
    func ownerOpens(_ url: String) {
        lock.withLock { windows[0].tabs.append(FakeTab(url: url, title: "Owner's", owner: "owner")) }
    }
}

/// What Latchkey noted for the Activity window's Left Behind list.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []
    var all: [String] { lock.withLock { made } }
    func add(_ s: String) { lock.withLock { made.append(s) } }
}

@Suite struct BrowserTabTests {
    func browser(_ fake: FakeSafariTabs, notes: Notes = Notes(), memory: WindowMemory? = nil) -> SafariBrowser {
        SafariBrowser(
            scripts: fake, settleLimit: .milliseconds(600), memory: memory, place: { .tab }, note: { notes.add($0) })
    }

    /// FR-412, FR-413: a new tab at the end of the Owner's front window, behind the tab the Owner
    /// is using; Claude reads its own tab only.
    @Test func opensABackgroundTabInTheOwnersWindow() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        let page = try await b.open("https://shop.example.com", newTab: false)
        #expect(page.text == "claude", "read Claude's tab")
        #expect(fake.userWindow.tabs.count == 3)
        #expect(fake.userWindow.tabs.last?.url == "https://shop.example.com")
        #expect(fake.userWindow.current == 1, "the Owner's tab stays in front")
        #expect(!fake.scripts.contains(SafariBrowser.Script.open), "no window of its own")
        #expect(fake.windows.count == 1)
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 && $0.checks == 0 }, "FR-403")
        _ = try await b.open("https://shop.example.com/cart", newTab: true)
        #expect(fake.userWindow.tabs.count == 3, "one tab of its own, also when asked for a new one (FR-416)")
        #expect(fake.claudeTabs.first?.url == "https://shop.example.com/cart")
    }

    /// FR-414: Safari without a window gets a new one, and Claude's page is its tab.
    @Test func opensAWindowWhenSafariHasNone() async throws {
        let fake = FakeSafariTabs(userTabs: [])
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        #expect(fake.windows.count == 1)
        #expect(fake.windows[0].tabs.map(\.owner) == ["claude"])
    }

    /// The Owner closes a tab to the left of Claude's: Claude's tab moved, and is still found by
    /// its mark; the Owner's tabs stay untouched.
    @Test func findsItsTabAfterTheOwnerClosesOneBeforeIt() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        fake.ownerCloses(tab: 1)
        let page = try await b.read(offset: 0)
        #expect(page.text == "claude")
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 }, "FR-403")
    }

    /// FR-403: the Owner closes Claude's tab and opens one in its place, even at the same
    /// address: Claude never reads it, and the lost tab is noted.
    @Test func neverTakesTheOwnersTabInItsPlace() async throws {
        for address in ["https://other.example.com/", "https://shop.example.com"] {
            let fake = FakeSafariTabs()
            let notes = Notes()
            let b = browser(fake, notes: notes)
            _ = try await b.open("https://shop.example.com", newTab: false)
            fake.ownerCloses(tab: 3)
            fake.ownerOpens(address)
            // Claude's last use was more than a moment ago.
            await b.age(by: 60)
            await #expect(throws: SafariBrowser.Failure.noWindow) { try await b.read(offset: 0) }
            #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 }, "read the Owner's tab at \(address)")
            #expect(notes.all.contains { $0.contains("lost track of Claude's Safari tab") })
        }
    }

    /// Security review 2026-10-29: Latchkey's own scripts keep Claude's last use fresh, so
    /// "Claude acted a moment ago" can't rest on it. Once Claude's page has loaded, a tab in
    /// its place without the mark is the Owner's, also at the address Claude loaded.
    @Test func surveysDontKeepTheLoadingAllowanceOpen() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        let deadline = Date().addingTimeInterval(2.5)  // past the allowance (settle limit + 1 s)
        while Date() < deadline {
            _ = try await b.read(offset: 0)  // every call is an Apple Event
            try await Task.sleep(for: .milliseconds(200))
        }
        fake.ownerCloses(tab: 3)
        fake.ownerOpens("https://shop.example.com")
        await #expect(throws: SafariBrowser.Failure.noWindow) { try await b.read(offset: 0) }
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 && $0.mark == nil }, "the Owner's tab was used")
    }

    /// While Claude's page loads, an Owner's tab in its place is still not Claude's: its address
    /// isn't the one Claude loaded.
    @Test func aTabInItsPlaceWhileLoadingIsNotTaken() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        _ = try await b.open("https://shop.example.com/cart", newTab: false)
        fake.ownerCloses(tab: 3)
        fake.ownerOpens("https://owner.example.com/")
        await #expect(throws: SafariBrowser.Failure.noWindow) { try await b.read(offset: 0) }
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 && $0.mark == nil })
    }

    /// A click that goes to another page keeps Claude's tab: the page said where it was going.
    @Test func aClickToAnotherPageKeepsTheTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        fake.clickGoesTo = "https://pay.example.net/checkout"
        let page = try await b.click("e1")
        #expect(page.url == "https://pay.example.net/checkout")
        #expect(fake.claudeTabs.first?.mark != nil, "marked again on the new page")
    }

    /// Security review 2026-10-29: an Owner's tab that slides into Claude's place between
    /// finding Claude's tab and acting on it (same tab count) is never run, loaded, closed, or
    /// brought forward.
    @Test(arguments: ["read", "open", "screenshot", "close"])
    func aTabSlidingInBeforeTheActionIsLeftAlone(_ action: String) async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        await b.age(by: 60)
        for address in ["https://owner.example.com/", "https://shop.example.com"] {
            fake.slideIn = address
            switch action {
            case "read": _ = try? await b.read(offset: 0)
            case "open": _ = try? await b.open("https://shop.example.com/next", newTab: false)
            case "screenshot": _ = try? await b.showing { $0 }
            default: _ = await b.closeIfIdle(after: 0)
            }
            let owners = fake.windows.flatMap(\.tabs).filter { $0.owner == "owner" }
            #expect(owners.count >= 3, "\(action): an Owner's tab was closed")
            #expect(owners.allSatisfy { $0.scriptsRun == 0 && $0.mark == nil }, "\(action): an Owner's tab was used")
            #expect(
                !owners.contains { $0.url == "https://shop.example.com/next" }, "\(action): loaded into the Owner's tab"
            )
            #expect(fake.userWindow.current == 1, "\(action): an Owner's tab was brought forward")
            // Start again from a fresh tab of Claude's for the second address.
            _ = try? await b.open("https://shop.example.com", newTab: false)
            await b.age(by: 60)
        }
    }

    /// FR-415: a screenshot brings Claude's tab forward, then the Owner's tab back.
    @Test func screenshotShowsClaudesTabThenTheOwnersAgain() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        let title = try await b.showing { title in
            fake.currentDuringShot = fake.userWindow.current
            return title
        }
        #expect(title == "Claude's")
        #expect(fake.currentDuringShot == 3, "Claude's tab was in front for the shot")
        #expect(fake.userWindow.current == 1, "and the Owner's tab is back")
        await #expect(throws: (any Error).self) {
            try await b.showing { _ -> String in throw SafariBrowser.Failure.failed("no screen") }
        }
        #expect(fake.userWindow.current == 1, "back also when the shot failed")
    }

    /// FR-411 in a tab: 30 minutes unused closes Claude's tab only, noted as Left Behind.
    @Test func idleClosesOnlyClaudesTab() async throws {
        let fake = FakeSafariTabs()
        let notes = Notes()
        let b = browser(fake, notes: notes)
        _ = try await b.open("https://shop.example.com", newTab: false)
        #expect(await !b.closeIfIdle(after: 1800))
        #expect(await b.closeIfIdle(after: 1800, now: Date().addingTimeInterval(1900)))
        #expect(fake.claudeTabs.isEmpty)
        #expect(fake.ownerTabs.count == 2)
        #expect(notes.all.last == "Closed Claude's Safari tab after 30 minutes unused")
        #expect(await !b.closeIfIdle(after: 0), "nothing left to close")
    }

    /// A tab Latchkey can't find any more isn't closed (it might be the Owner's now); the
    /// Left Behind list says so.
    @Test func idleCloseOfALostTabSaysSo() async throws {
        let fake = FakeSafariTabs()
        let notes = Notes()
        let b = browser(fake, notes: notes)
        _ = try await b.open("https://shop.example.com", newTab: false)
        fake.ownerCloses(tab: 3)
        fake.ownerOpens("https://owner.example.com/")
        #expect(await b.closeIfIdle(after: 1800, now: Date().addingTimeInterval(1900)))
        #expect(fake.ownerTabs.count == 3, "the Owner's new tab stays")
        #expect(notes.all.contains { $0.contains("lost track") })
    }

    /// A restarted Latchkey still closes Claude's tab, in the same run of Safari.
    @Test func aRestartRemembersClaudesTab() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tab-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "safari-window.json")
        let fake = FakeSafariTabs()
        _ = try await browser(fake, memory: WindowMemory(file: file) { "100 1" }).open(
            "https://shop.example.com", newTab: false)
        #expect(WindowMemory(file: file) { nil }.load()?.tab?.index == 3)
        let notes = Notes()
        let restarted = browser(fake, notes: notes, memory: WindowMemory(file: file) { "100 1" })
        #expect(await restarted.closeIfIdle(after: 1800, now: Date().addingTimeInterval(1900)))
        #expect(fake.claudeTabs.isEmpty)
        #expect(fake.ownerTabs.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// FR-416: in a tab, Claude's tabs are the one it opened.
    @Test func listsOnlyItsOwnTab() async throws {
        let fake = FakeSafariTabs()
        let b = browser(fake)
        _ = try await b.open("https://shop.example.com", newTab: false)
        let t = try await b.tabs(select: nil)
        #expect(t.current == 1)
        #expect(t.tabs.count == 1)
        #expect(t.tabs.first?.2 == "https://shop.example.com")
        await #expect(throws: SafariBrowser.Failure.self) { _ = try await b.tabs(select: 2) }
        #expect(fake.ownerTabs.allSatisfy { $0.scriptsRun == 0 })
    }

    /// FR-417: changing the setting takes effect at the next page Claude opens; the old window
    /// closes, so nothing is left behind.
    @Test func changingTheSettingMovesToATab() async throws {
        let fake = FakeSafariTabs()
        let place = PlaceBox(.window)
        let b = SafariBrowser(scripts: fake, settleLimit: .milliseconds(600), place: { place.value })
        _ = try await b.open("https://w.example.com", newTab: false)
        #expect(fake.windows.contains { $0.id == 77 })
        place.value = .tab
        _ = try await b.open("https://shop.example.com", newTab: false)
        #expect(!fake.windows.contains { $0.id == 77 }, "Claude's window closed")
        #expect(fake.claudeTabs.count == 1)
        place.value = .window
        _ = try await b.open("https://w.example.com", newTab: false)
        #expect(fake.claudeTabs.isEmpty, "Claude's tab closed")
        #expect(fake.windows.contains { $0.id == 77 })
    }

    /// Which tab is Claude's, decided from what Safari reports (plan D6).
    @Test func picksClaudesTab() {
        let mine = ClaudeTab(index: 3, count: 3, address: "https://a/", token: "t")
        func survey(_ count: Int, _ rows: [(Bool, Bool)], loadingAt: Int? = 3) -> TabSurvey {
            TabSurvey(
                count: count,
                rows: rows.enumerated().map {
                    TabSurvey.Row(index: $0 + 1, sameAddress: $1.0, marked: $1.1, loading: $0 + 1 == loadingAt)
                }
            )
        }
        #expect(
            TabSurvey.pick(
                survey(3, [(false, false), (false, false), (false, false)], loadingAt: nil), remembered: mine,
                navigating: true)
                == nil, "loading, but not the address Claude loaded")
        let three = [(false, false), (false, false)]
        #expect(TabSurvey.pick(survey(3, three + [(true, true)]), remembered: mine, navigating: false) == 3)
        #expect(
            TabSurvey.pick(survey(2, [(false, false), (true, true)]), remembered: mine, navigating: false) == 2, "moved"
        )
        #expect(
            TabSurvey.pick(survey(3, three + [(false, false)]), remembered: mine, navigating: true) == 3,
            "Claude's own page is still loading")
        #expect(
            TabSurvey.pick(survey(3, three + [(true, false)]), remembered: mine, navigating: false) == nil,
            "same address but not marked: may be the Owner's")
        #expect(
            TabSurvey.pick(survey(4, three + [(false, false), (false, false)]), remembered: mine, navigating: true)
                == nil)
        #expect(
            TabSurvey.pick(
                survey(3, [(true, false), (false, false), (false, false)]), remembered: mine, navigating: false)
                == nil)
        #expect(TabSurvey("3\n1\tfalse\tfalse\n2\tfalse\tfalse\n3\ttrue\ttrue\n").rows.last?.marked == true)
        #expect(TabSurvey("1\n1\tfalse\tfalse\ttrue\n").rows.first?.loading == true)
    }

    @Test func settingStartsAsATab() {
        #expect(BrowserPlace.stored(in: UserDefaults(suiteName: "browser-place-\(UUID().uuidString)")!) == .tab)
    }
}

final class PlaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrowserPlace
    init(_ p: BrowserPlace) { stored = p }
    var value: BrowserPlace {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Claude's mark in a real WebKit page (plan D6): set before a script, read back as yes or no.
@Suite(.serialized) struct TabMarkTests {
    @MainActor @Test func marksThePageAndChecksOnlyYesOrNo() async throws {
        let page = TestPage()
        try await page.load()
        #expect(try await page.run(PageScripts.tabCheck("abc123")) == "no")
        let stamp = try await page.run(PageScripts.tabMark("abc123") + PageScripts.stamp)
        #expect(stamp.contains("|complete|"), "the script after the mark still answers")
        #expect(try await page.run(PageScripts.tabCheck("abc123")) == "yes")
        #expect(try await page.run(PageScripts.tabCheck("other")) == "no")
        #expect(try await page.run("Object.keys(window).includes('__latchkeyTab') ? 'seen' : 'hidden'") == "hidden")
        try await page.load()
        #expect(try await page.run(PageScripts.tabCheck("abc123")) == "no", "a new page loses the mark")
    }
}

/// Where Claude's page says it is going (plan D6), from WebKit's Navigation API.
@Suite(.serialized) struct TabGoalTests {
    @MainActor @Test func notesWhereThePageIsGoing() async throws {
        let page = TestPage()
        try await page.load()
        _ = try await page.run(PageScripts.tabMark("abc123") + "'ok'")
        #expect(try await page.run(PageScripts.takeDestination) == "", "nothing yet")
        _ = try await page.run(PageScripts.tabMark("abc123") + "location.hash = 'next'; 'ok'")
        #expect(try await page.run(PageScripts.takeDestination) == "https://shop.example.com/#next")
        #expect(try await page.run(PageScripts.takeDestination) == "", "asking clears it")
    }

    @Test func spellsAddressesAsRedirectsDo() {
        let s = SafariBrowser.spellings(of: ["https://example.com"])
        for a in ["https://example.com", "https://example.com/", "http://example.com/", "https://www.example.com/"] {
            #expect(s.contains(a), "\(a)")
        }
        #expect(!s.contains("https://other.example/"))
        let path = SafariBrowser.spellings(of: ["https://www.shop.example.com/cart?x=1"])
        #expect(path.contains("https://shop.example.com/cart/?x=1"))
        #expect(path.contains("https://www.shop.example.com/cart?x=1"))
    }
}
