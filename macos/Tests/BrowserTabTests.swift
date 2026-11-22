import Foundation
import Testing

@testable import Latchkey

/// Plays Safari with windows and tabs, for the Owner's tabs Claude works in (spec 005 FR-424 to
/// FR-431). Answers the tab scripts the way Safari would, and records which tabs ran which script,
/// so a test can tell which tabs were read or changed.
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
        /// Times Latchkey picked this tab for Claude to work in (2026-11-03).
        var picks = 0
        /// A page Safari lets no script into (an empty tab, Safari's own pages).
        var scriptless = false
        /// The page waits on a dialog it showed: no script answers (FR-432).
        var waiting = false
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
    /// Set to an address: right before the next script that acts on the picked tab (after
    /// Latchkey found it), the Owner closes the picked tab and opens one at that address in its
    /// place, so the tab count stays the same.
    var slideIn: String?
    /// Set to an address: the next click in the picked tab is on a link to that page. As in real
    /// Safari (2026-10-29), the link's `navigate` event comes only after the click script
    /// returned, and the new page has replaced the old one before Latchkey's next script, so
    /// no note of it is ever read: only the click script's own answer names the address.
    var clickGoesTo: String?
    /// What the page's dialogs said, as the script that takes them answers; once (FR-432).
    var dialogsSaid = "[]"
    /// Plays a page whose click handler changes the link's address as it is clicked.
    var clickChangesLink = false
    /// Set to an address: the next click in the picked tab is on a button that sends the page
    /// there; the `navigate` event comes after the click script, while the acting script waits
    /// for it, then the new page replaces the old one.
    var buttonGoesTo: String?
    /// Set to an address: the next script in the picked tab sets `location.href` to it; the
    /// `navigate` event fires during the script, and the page is replaced right after.
    var scriptGoesTo: String?
    /// Set to an address: going back goes there, its `navigate` event too late, as for a link.
    var backGoesTo: String?
    /// Set to an address: every script in the picked tab reports that its page is going there,
    /// in the script's own run and whenever asked afterwards (a page forging its note).
    var pageGoal: String?
    /// False: Safari's "Allow JavaScript from Apple Events" is off (FR-406).
    var javaScriptAllowed = true

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
    var scripts: [String] { lock.withLock { calls.map(\.script) } }

    private func window(_ id: String) throws -> Int {
        guard let w = windows.firstIndex(where: { String($0.id) == id }) else {
            throw ScriptError.failed("execution error: LATCHKEY_NO_WINDOW (-2700)")
        }
        return w
    }

    private func marked(_ tab: FakeTab, _ checkJS: String) -> Bool {
        tab.mark.map { checkJS.contains("\"\($0)\"") } ?? false
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
        let waiting = windows[w].tabs[i].waiting
        guard (!waiting && marked(windows[w].tabs[i], args[3])) || loading else {
            throw ScriptError.failed(
                "execution error: \(waiting ? "LATCHKEY_DIALOG_WAITING" : "LATCHKEY_MOVED") (-2700)")
        }
        return (w, i)
    }

    private static func token(in js: String) -> String? {
        // The token is spliced in as a JSON string literal (Semgrep rule, 2026-10-30).
        guard let r = js.range(of: #"__latchkeyTab', \{ value: "([0-9a-f]+)""#, options: .regularExpression) else {
            return nil
        }
        let found = js[r]
        return found.split(separator: "\"").dropFirst().first.map(String.init)
    }

    func run(_ script: String, _ args: [String]) async throws -> String {
        try lock.withLock {
            calls.append((script, args))
            switch script {
            case SafariBrowser.Script.tabNew:
                // Claude's own tab, at the end of the front window, behind the Owner's (FR-455).
                guard !windows.isEmpty else { return "none" }
                loads += 1
                windows[0].tabs.append(FakeTab(url: args[0], title: "Claude's", owner: "claude"))
                let n = windows[0].tabs.count
                return "\(windows[0].id)\t\(n)\t\(n)"
            case SafariBrowser.Script.tabLoad:
                let (w, i) = try guarded(args)
                windows[w].tabs[i].waiting = false  // a new page replaces the one waiting
                loads += 1
                windows[w].tabs[i].url = args[5]
                windows[w].tabs[i].mark = nil
                windows[w].tabs[i].scriptsRun += 1
                return ""
            case SafariBrowser.Script.allTabs:
                // Every browser window front to back: its id and front tab, then its tabs.
                var out = ""
                for w in windows {
                    out += "W\t\(w.id)\t\(w.current)\n"
                    for (i, t) in w.tabs.enumerated() { out += "T\t\(i + 1)\t\(t.title)\t\(t.url)\n" }
                }
                return out
            case SafariBrowser.Script.tabPick:
                let i = Int(args[1])! - 1
                guard let w = windows.firstIndex(where: { String($0.id) == args[0] }), i >= 0, i < windows[w].tabs.count
                else {
                    throw ScriptError.failed("execution error: LATCHKEY_NO_TAB (-2700)")
                }
                if let token = Self.token(in: args[2]), !windows[w].tabs[i].scriptless {
                    windows[w].tabs[i].mark = token
                }
                windows[w].tabs[i].picks += 1
                let marked = windows[w].tabs[i].mark == nil ? "no" : "yes"
                return "\(windows[w].tabs.count)\t\(marked)\t\(windows[w].tabs[i].url)"
            case SafariBrowser.Script.tabSurvey:
                let w = try window(args[0])
                let idx = Int(args[1])!
                let expected = args[4].split(separator: "\n").map(String.init)
                var out = "\(windows[w].tabs.count)\n"
                for i in windows[w].tabs.indices {
                    let same = windows[w].tabs[i].url == args[2]
                    var isMarked = false
                    var loading = false
                    let waiting = windows[w].tabs[i].waiting && (i + 1 == idx || same)
                    if i + 1 == idx || same {
                        windows[w].tabs[i].checks += 1
                        isMarked = !waiting && marked(windows[w].tabs[i], args[3])
                    }
                    if i + 1 == idx { loading = expected.contains(windows[w].tabs[i].url) }
                    out += "\(i + 1)\t\(same)\t\(isMarked)\t\(loading)\t\(waiting)\t\(windows[w].tabs[i].url)\n"
                }
                return out
            case SafariBrowser.Script.tabJavaScript:
                let (w, i) = try guarded(args)
                if windows[w].tabs[i].waiting {
                    throw ScriptError.failed("execution error: LATCHKEY_DIALOG_WAITING (-2700)")
                }
                let js = args[5]
                let waits = args.count > 7 && args[7] == "yes"
                windows[w].tabs[i].scriptsRun += 1
                if let token = Self.token(in: js) { windows[w].tabs[i].mark = token }
                let tab = windows[w].tabs[i]
                func encoded(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)! }
                var answer: String
                var goesTo: String?
                var late = false  // the navigate event comes after the script returned
                if !javaScriptAllowed {
                    throw ScriptError.failed(
                        "Safari got an error: You must enable the “Allow JavaScript from Apple Events” option in Safari’s Develop menu to use “do JavaScript”. (8)"
                    )
                }
                if js.contains("timeOrigin") {
                    answer = "\(loads)|complete|\(tab.url)"
                } else if js.contains("latchkeyRead") {
                    answer =
                        #"{"title":"The owner's page","url":"\#(tab.url)","total":5,"text":"\#(tab.owner)","elements":[]}"#
                } else if js.contains("document.title") {
                    answer = "\(tab.title)\t\(tab.url)"
                } else {
                    answer = "ok"
                }
                var inRun = pageGoal ?? ""
                if js.contains("e.click()"), let next = clickGoesTo {
                    clickGoesTo = nil
                    goesTo = next
                    // Only a click script that reports the link's address (Latchkey's own) does.
                    if js.contains("closest('a[href]')") {
                        answer += "\n" + encoded(next)
                        // Latchkey's script adds "same" when the link's address didn't change in the click.
                        if js.contains("after === before"), !clickChangesLink { answer += "\n" + encoded("same") }
                    }
                } else if js.contains("e.click()"), let next = buttonGoesTo {
                    buttonGoesTo = nil
                    goesTo = next
                    late = true
                } else if js.contains("history.back()"), let next = backGoesTo {
                    backGoesTo = nil
                    goesTo = next
                    if js.contains("entries()") { answer += "\n" + encoded(next) }
                } else if let next = scriptGoesTo {
                    scriptGoesTo = nil
                    goesTo = next
                    inRun = next
                }
                // The note asked for after the script: by an acting script that waits, the
                // button's (the old page is still there when its event comes); a link's page
                // is already gone; with no navigation, whatever the page reports.
                let wrapped = js.contains("JSON.stringify([r === undefined")
                let asked = wrapped ? waits : true
                var later = ""
                if asked {
                    if goesTo == nil { later = pageGoal ?? "" } else if late && wrapped { later = goesTo! }
                }
                if let goesTo {
                    loads += 1
                    windows[w].tabs[i].url = goesTo
                    windows[w].tabs[i].mark = nil
                }
                let run =
                    wrapped
                    ? String(data: try! JSONEncoder().encode([answer, encoded(inRun)]), encoding: .utf8)! : answer
                defer { dialogsSaid = "[]" }
                return windows[w].tabs[i].url + "\n" + encoded(later) + "\n" + dialogsSaid + "\n" + run
            case SafariBrowser.Script.tabFront:
                let (w, i) = try guarded(args)
                let shown = windows[w].tabs[windows[w].current - 1].title
                return "\(windows[w].current == i + 1)\t\(shown)\t\(windows[w].tabs[i].url)"
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
            default:
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

/// The navigation rules of plan D6 and D8 in one of the Owner's tabs Claude works in: where a
/// page may go after Claude's own click, typing, or back and still be the same tab, and which
/// tab is never taken for it (security reviews 2026-10-29 to 2026-11-03). Tab 10.2 shows
/// https://news.example.com/.
@Suite struct OwnerTabNavigationTests {
    func picked(_ fake: FakeSafariTabs) async throws -> SafariBrowser {
        // 10 s: the allowance (the limit plus 1 s) must outlast a slow moment while every suite
        // runs side by side (3 s ran out at 4.05 s, 2026-11-15).
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(10))
        try await b.pick("10.2")
        _ = try await b.read(offset: 0)  // marked, as any use marks it
        return b
    }

    /// Security review 2026-10-29: Latchkey's own scripts keep the last use fresh, so "Claude
    /// acted a moment ago" can't rest on it: a tab in the picked one's place without the mark is
    /// another, also at the same address.
    @Test func surveysDontKeepTheLoadingAllowanceOpen() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        for _ in 0..<3 { _ = try await b.read(offset: 0) }
        await b.age(by: 60)
        for _ in 0..<3 { _ = try await b.read(offset: 0) }
        fake.ownerCloses(tab: 2)
        fake.ownerOpens("https://news.example.com/")
        await #expect(throws: SafariBrowser.Failure.tabGone) { try await b.read(offset: 0) }
        #expect(fake.windows[0].tabs[1].scriptsRun == 0 && fake.windows[0].tabs[1].mark == nil, "the new tab was used")
    }

    /// While a page Claude's click loaded is loading, a tab in its place is still not the picked
    /// one: its address isn't the one the click went to.
    @Test func aTabInItsPlaceWhileLoadingIsNotTaken() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.clickGoesTo = "https://news.example.com/cart"
        _ = try await b.click("e1")
        fake.ownerCloses(tab: 2)
        fake.ownerOpens("https://owner.example.com/")
        await #expect(throws: SafariBrowser.Failure.tabGone) { try await b.read(offset: 0) }
        #expect(fake.windows[0].tabs[1].scriptsRun == 0 && fake.windows[0].tabs[1].mark == nil)
    }

    /// A click that goes to another page keeps the tab: the page said where it was going.
    /// Security review 2026-10-29: a page that keeps saying it is going somewhere opens the
    /// loading allowance at most once per action of Claude's.
    @Test func aPageReportsWhereItGoesOncePerAction() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.pageGoal = "https://news.example.com/cart"
        let before = Date()
        _ = try await b.click("e1")  // several scripts in one action, each reporting the goal
        let first = try #require(await b.navigationState())
        #expect(first.addresses.contains("https://news.example.com/cart"))
        #expect(first.since < before.addingTimeInterval(0.4), "set by the first report only")
        // Later actions (or interleaved ones) can't move it forward while the allowance a note
        // opened is still open.
        _ = try await b.read(offset: 0)
        let second = try #require(await b.navigationState())
        #expect(second.since == first.since, "a note can't keep the allowance open")
    }

    /// Security review 2026-10-29: a page can only name an address on its own site.
    @Test func aNoteOfAnotherSiteIsIgnored() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.pageGoal = "https://owner.example.com/"
        _ = try await b.click("e1")
        let state = await b.navigationState()
        #expect(
            state.map { !$0.addresses.contains("https://owner.example.com/") } ?? true, "\(String(describing: state))")
    }

    /// Security review 2026-10-29: a read can't open the allowance, however often the page
    /// reports; only Claude's own click, typing, or back can.
    @Test func aReadNeverOpensTheAllowance() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.pageGoal = "https://news.example.com/cart"
        _ = try await b.read(offset: 0)
        #expect(await b.navigationState() == nil, "a read opened the allowance")
    }

    /// A noted address is used only when it is one web address on one line.
    @Test func noteOfWhereThePageGoesIsChecked() {
        #expect(
            SafariBrowser.goal(fromNote: #""https://pay.example.net/checkout""#) == "https://pay.example.net/checkout")
        #expect(SafariBrowser.goal(fromNote: #""""#) == nil)
        #expect(SafariBrowser.goal(fromNote: #""https://a.example/\nhttps://owner.example/""#) == nil, "a line break")
        #expect(SafariBrowser.goal(fromNote: #""https://a.example/\r""#) == nil)
        #expect(SafariBrowser.goal(fromNote: "https://a.example/") == nil, "not JSON")
        #expect(SafariBrowser.goal(fromNote: #""javascript:alert(1)""#) == nil)
        #expect(SafariBrowser.goal(fromNote: #""https://a.example/ x""#) == nil, "a space")
    }

    /// Live check 2026-10-29: in real Safari a link's `navigate` event comes after the click
    /// script, and the new page has replaced the old one before Latchkey asks for the note. The
    /// click script's own answer names the link.
    @Test func aLinkClickToAnotherPageKeepsTheTab() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.clickGoesTo = "https://news.example.com/checkout"
        let page = try await b.click("e1")
        #expect(page.url == "https://news.example.com/checkout")
        #expect(fake.windows[0].tabs[1].mark != nil, "marked again on the new page")
        #expect(try await b.read(offset: 0).url == "https://news.example.com/checkout")
        #expect(fake.windows[0].tabs[0].scriptsRun == 0 && fake.windows[0].tabs[0].mark == nil)
    }

    /// A button that sends the page elsewhere: its note comes after the click script, while
    /// the acting script waits for it.
    @Test func aButtonThatGoesToAnotherPageKeepsTheTab() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.buttonGoesTo = "https://news.example.com/done"
        #expect(try await b.click("e1").url == "https://news.example.com/done")
    }

    /// Back to the previous page: the entry's address comes from the back script itself.
    @Test func goingBackKeepsTheTab() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.backGoesTo = "https://news.example.com/before"
        #expect(try await b.back().url == "https://news.example.com/before")
    }

    /// Security review 2026-11-01: a page whose click handler changes the link's address can't
    /// name another site; the tab is lost.
    @Test func aLinkChangedByThePageInTheClickLosesTheTab() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.clickGoesTo = "https://pay.example.net/"
        fake.clickChangesLink = true
        await #expect(throws: SafariBrowser.Failure.tabGone) { _ = try await b.click("e1") }
        #expect(await b.working() == nil)
        #expect(fake.windows[0].tabs[0].scriptsRun == 0 && fake.windows[0].tabs[0].mark == nil, "the other tab")
    }

    /// The note a script's own run takes counts during Claude's click: a button whose handler
    /// sets `location.href` fires the `navigate` event inside the click script.
    @Test func aNoteInTheClickScriptsOwnRunCounts() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        fake.pageGoal = "https://news.example.com/cart"
        _ = try await b.click("e1")
        #expect(await b.navigationState()?.addresses.contains("https://news.example.com/cart") == true)
    }

    /// Security review 2026-10-29: a tab that slides into the picked one's place between finding
    /// it and acting on it (same tab count) is never run, closed, or brought forward.
    @Test(arguments: ["read", "screenshot", "close"])
    func aTabSlidingInBeforeTheActionIsLeftAlone(_ action: String) async throws {
        for address in ["https://owner.example.com/", "https://news.example.com/"] {
            let fake = FakeSafariTabs()
            let b = try await picked(fake)
            fake.slideIn = address
            switch action {
            case "read": _ = try? await b.read(offset: 0)
            case "screenshot": _ = try? await b.showing { $0 }
            default: _ = try? await b.closeWorking()
            }
            let slid = fake.windows[0].tabs[1]
            #expect(fake.windows[0].tabs.count == 2, "\(action): a tab was closed")
            #expect(slid.scriptsRun == 0 && slid.mark == nil, "\(action): the tab in its place was used")
            #expect(fake.userWindow.current == 1, "\(action): a tab was brought forward")
        }
    }

    /// FR-415, FR-427: a picture brings the tab forward for the shot, then the Owner's front tab
    /// back, also when the shot failed.
    @Test func aPictureShowsTheTabThenTheFrontTabAgain() async throws {
        let fake = FakeSafariTabs()
        let b = try await picked(fake)
        let title = try await b.showing { title in
            fake.currentDuringShot = fake.userWindow.current
            return title
        }
        #expect(title == "Owner's")
        #expect(fake.currentDuringShot == 2, "the tab was in front for the shot")
        #expect(fake.userWindow.current == 1, "and the Owner's front tab is back")
        await #expect(throws: (any Error).self) {
            try await b.showing { _ -> String in throw SafariBrowser.Failure.failed("no screen") }
        }
        #expect(fake.userWindow.current == 1, "back also when the shot failed")
    }

    /// Citi, 2026-11-21: Claude's own tab, sent on by the site (www.citi.com to online.citi.com,
    /// no mark, not an address Latchkey loaded) after the load's limit: found again and used, not
    /// "Safari's tabs changed" on every call. Another tab changing still loses it.
    @Test func claudesOwnTabIsUsedAfterTheSiteSendsItOn() async throws {
        let fake = FakeSafariTabs()
        let b = SafariBrowser(scripts: fake, settleLimit: .milliseconds(200))
        _ = try await b.openTab("https://www.citi.com/")
        try await Task.sleep(for: .milliseconds(1500))  // past the load's allowance
        let n = fake.windows[0].tabs.count - 1
        fake.windows[0].tabs[n].url = "https://online.citi.com/US/ag/dashboard/summary"
        fake.windows[0].tabs[n].mark = nil
        let page = try await b.read(offset: 0)
        #expect(page.url == "https://online.citi.com/US/ag/dashboard/summary")
        #expect(try await b.read(offset: 0).url == page.url, "marked again: the next call works too")
        fake.windows[0].tabs[n].mark = nil
        fake.windows[0].tabs[0].url = "https://mail.example.com/other"
        await #expect(throws: SafariBrowser.Failure.tabGone) { _ = try await b.read(offset: 0) }
    }

    /// Citi, 2026-11-21: a tab of Claude's own whose page redirected after the load's limit (no
    /// mark, not the address loaded) is still Claude's while every other tab is as it was; an
    /// owner's tab never is, and a change to any other tab loses it.
    @Test func claudesOwnTabSurvivesARedirect() {
        func row(_ i: Int, _ address: String) -> TabSurvey.Row {
            TabSurvey.Row(index: i, sameAddress: false, marked: false, address: address)
        }
        let before = TabSurvey(
            count: 3, rows: [row(1, "https://o/1"), row(2, "https://o/2"), row(3, "https://www.citi.com/")])
        var mine = PickedTab(index: 3, count: 3, address: "https://online.citi.com/US/ag/dashboard", token: "t")
        mine.others = before.fingerprint(without: 3)
        let after = TabSurvey(
            count: 3, rows: [row(1, "https://o/1"), row(2, "https://o/2"), row(3, "https://online.citi.com/US/login")])
        #expect(TabSurvey.pick(after, remembered: mine, navigating: false, claudes: true) == 3)
        #expect(TabSurvey.pick(after, remembered: mine, navigating: false, claudes: false) == nil, "an owner's tab")
        let ownerMoved = TabSurvey(
            count: 3,
            rows: [row(1, "https://o/1"), row(2, "https://o/other"), row(3, "https://online.citi.com/US/login")])
        #expect(TabSurvey.pick(ownerMoved, remembered: mine, navigating: false, claudes: true) == nil)
        let opened = TabSurvey(
            count: 4,
            rows: [
                row(1, "https://o/1"), row(2, "https://o/2"), row(3, "https://online.citi.com/US/login"), row(4, "x"),
            ])
        #expect(TabSurvey.pick(opened, remembered: mine, navigating: false, claudes: true) == nil)
        // Security review 2026-11-21: the owner closed Claude's tab and opened one of theirs in
        // its place, on another site: never taken for Claude's.
        let ownersInItsPlace = TabSurvey(
            count: 3, rows: [row(1, "https://o/1"), row(2, "https://o/2"), row(3, "https://mail.example.com/inbox")])
        #expect(TabSurvey.pick(ownersInItsPlace, remembered: mine, navigating: false, claudes: true) == nil)
    }

    /// Which tab is the picked one, decided from what Safari reports (plan D6, D8).
    @Test func picksThePickedTab() {
        let mine = PickedTab(index: 3, count: 3, address: "https://a/", token: "t")
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
                == nil, "loading, but not the address Claude's action loaded")
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
            "same address but not marked: may be another tab")
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
        #expect(try await page.run(PageScripts.takeDestination) == #""""#, "nothing yet")
        _ = try await page.run(PageScripts.tabMark("abc123") + "location.hash = 'next'; 'ok'")
        #expect(try await page.run(PageScripts.takeDestination) == #""https://shop.example.com/#next""#)
        #expect(try await page.run(PageScripts.takeDestination) == #""""#, "asking clears it")
    }

    /// Security review 2026-10-29: the page can't write the note; only its own navigation does.
    @MainActor @Test func thePageCantWriteTheNote() async throws {
        let page = TestPage()
        try await page.load()
        _ = try await page.run(PageScripts.tabMark("abc123") + "'ok'")
        _ = try await page.run(
            """
            window.__latchkeyGoal = 'https://owner.example.com/';
            try { Object.defineProperty(window, '__latchkeyGoal', { value: 'https://owner.example.com/' }); } catch (e) {}
            window.__latchkeyListens = false;
            'ok'
            """)
        #expect(try await page.run(PageScripts.takeDestination) == #""""#)
        _ = try await page.run(PageScripts.tabMark("abc123") + "'ok'")
        #expect(try await page.run(PageScripts.takeDestination) == #""""#, "marking again changes nothing")
    }

    /// A page that puts its own note in place before Latchkey's is not believed.
    @MainActor @Test func aNoteThePageMadeFirstIsIgnored() async throws {
        for setup in [
            "window.__latchkeyGoal = 'https://owner.example.com/'; 'ok'",
            "Object.defineProperty(window, '__latchkeyGoal', { get: function () { return 'https://owner.example.com/'; }, configurable: true }); 'ok'",
            "Object.defineProperty(window, '__latchkeyGoal', { get: function () { return 'https://owner.example.com/'; }, set: function () {} }); 'ok'",
        ] {
            let page = TestPage()
            try await page.load()
            _ = try await page.run(setup)
            _ = try await page.run(PageScripts.tabMark("abc123") + "'ok'")
            #expect(try await page.run(PageScripts.takeDestination) == #""""#, "\(setup)")
        }
    }

    /// Real Safari, 2026-10-29: a script that sends the page elsewhere fires `navigate` during
    /// the script, and the page is gone by the next script, so the note is taken in the same run.
    @MainActor @Test func theNoteIsTakenInTheScriptsOwnRun() async throws {
        let page = TestPage()
        try await page.load()
        let out = try await page.run(
            PageScripts.tabMark("abc123") + PageScripts.inTab("(location.hash = 'next', 'done')"))
        let both = try JSONDecoder().decode([String].self, from: Data(out.utf8))
        #expect(both == ["done", #""https://shop.example.com/#next""#])
        let none = try await page.run(PageScripts.tabMark("abc123") + PageScripts.inTab("undefined"))
        #expect(try JSONDecoder().decode([String].self, from: Data(none.utf8)) == ["", #""""#])
        let thrown = try await page.run(
            PageScripts.tabMark("abc123") + PageScripts.inTab("(function () { throw 1; })()"))
        #expect(try JSONDecoder().decode([String].self, from: Data(thrown.utf8)) == ["", #""""#])
    }

    /// A page without Latchkey's note at all (a new page) answers null, so waiting stops.
    @MainActor @Test func aNewPageHasNoNote() async throws {
        let page = TestPage()
        try await page.load()
        #expect(try await page.run(PageScripts.takeDestination) == "null")
    }

    /// The click script names the link it clicked, read after the page's own click handlers.
    @MainActor @Test func theClickScriptNamesTheLink() async throws {
        let page = TestPage()
        try await page.load(
            """
            <html><body>
            <a id="a" href="/next" onclick="this.href = '/tracked'; return false;">Next</a>
            <a id="b" href="/other" target="_blank" onclick="return false;">Elsewhere</a>
            <button id="c" onclick="return false;">Buy</button>
            </body></html>
            """)
        _ = try await page.run(PageScripts.read(offset: 0))
        let refs = try PageScripts.decode(try await page.run(PageScripts.read(offset: 0))).elements.map(\.ref)
        try #require(refs.count == 3, "the page's three elements, before any is clicked")
        // Its handler cancels the click (return false): no address to go to (2026-11-16, a
        // cancelled link was followed); a link that isn't cancelled is in aCancelledLinkIsNotFollowed.
        #expect(try await page.run(PageScripts.click(refs[0])) == "ok")
        #expect(try await page.run(PageScripts.click(refs[1])) == "ok", "a new tab isn't Claude's tab")
        #expect(try await page.run(PageScripts.click(refs[2])) == "ok")
        #expect(try await page.run(PageScripts.back) == "ok", "no entry to go back to")
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
