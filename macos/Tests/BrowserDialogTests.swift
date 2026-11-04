import Foundation
import Testing
import WebKit

@testable import Latchkey

/// Spec 005 FR-432 (Toni, 2026-11-03: "Answer them, Claude can say OK"): a page's own dialogs
/// never make Claude wait. Latchkey's answers go into the page before each script; a page that
/// already waits on a dialog is told within 2 s, and can be loaded over or closed.
@Suite(.serialized) struct BrowserDialogTests {
    static let html = """
        <html><head><title>Shop</title></head><body>
        <button id="del" onclick="document.title = 'asked:' + confirm('Delete the order?')">Delete</button>
        <button id="name" onclick="document.title = 'named:' + prompt('Your name?')">Name</button>
        <button id="hi" onclick="alert('Saved\\nfor «you»'); document.title = 'alerted'">Save</button>
        </body></html>
        """

    func said(_ page: TestPage) async throws -> [[String]] {
        let json = try await page.run(PageScripts.takeDialogs)
        return try JSONDecoder().decode([[String]].self, from: Data(json.utf8))
    }

    @MainActor @Test func aConfirmGetsCancelUnlessClaudeSaysOK() async throws {
        let page = TestPage()
        try await page.load(Self.html)
        _ = try await page.run(
            PageScripts.dialogAnswers(DialogAnswer()) + "document.getElementById('del').click(); document.title")
        #expect(try await page.run("document.title") == "asked:false")
        _ = try await page.run(
            PageScripts.dialogAnswers(DialogAnswer(confirm: true))
                + "document.getElementById('del').click(); document.title")
        #expect(try await page.run("document.title") == "asked:true")
        let log = try await said(page)
        #expect(log == [["confirm", "Delete the order?", "cancel"], ["confirm", "Delete the order?", "ok"]])
        #expect(try await said(page).isEmpty, "taken once")
    }

    @MainActor @Test func aPromptGetsClaudesTextOrNothingAndAnAlertIsDismissed() async throws {
        let page = TestPage()
        try await page.load(Self.html)
        _ = try await page.run(
            PageScripts.dialogAnswers(DialogAnswer(text: "Toni")) + "document.getElementById('name').click(); 1")
        #expect(try await page.run("document.title") == "named:Toni")
        _ = try await page.run(PageScripts.dialogAnswers(DialogAnswer()) + "document.getElementById('name').click(); 1")
        #expect(try await page.run("document.title") == "named:null")
        _ = try await page.run(PageScripts.dialogAnswers(DialogAnswer()) + "document.getElementById('hi').click(); 1")
        #expect(try await page.run("document.title") == "alerted")
        let log = try await said(page)
        #expect(log.map(\.first) == ["prompt", "prompt", "alert"])
    }

    @Test func notesAreOneLineAndCantPoseAsLatchkey() {
        let n = PageScripts.dialogNote(kind: "alert", message: "Saved\nfor «you»", answer: nil)
        #expect(n == "The page showed an alert: «Saved for \"you\"» (dismissed).")
        #expect(
            PageScripts.dialogNote(kind: "confirm", message: "Sure?", answer: "ok")
                == "The page asked to confirm: «Sure?»; Latchkey answered OK.")
        #expect(
            PageScripts.dialogNote(kind: "prompt", message: "Name?", answer: "")
                == "The page asked for text: «Name?»; Latchkey gave none.")
        #expect(
            PageScripts.dialogNote(kind: "alert", message: String(repeating: "x", count: 500), answer: nil).count < 260)
    }

    @Test func theSurveyTellsAWaitingPage() {
        let s = TabSurvey(
            "3\n1\tfalse\tfalse\tfalse\tfalse\n2\ttrue\tfalse\tfalse\ttrue\n3\tfalse\tfalse\tfalse\tfalse\n")
        #expect(s.rows[1].waiting && !s.rows[0].waiting)
        let t = ClaudeTab(index: 2, count: 3, address: "https://shop.example.com/", token: "ab")
        #expect(TabSurvey.pick(s, remembered: t, navigating: false) == 2, "where it was, as many tabs, same address")
        var moved = t
        moved.count = 4
        #expect(TabSurvey.pick(s, remembered: moved, navigating: false) == nil, "tabs changed: not surely Claude's")
    }

    func tabBrowser(_ fake: FakeSafariTabs) -> SafariBrowser {
        SafariBrowser(scripts: fake, settleLimit: .seconds(3), memory: nil, place: { .tab }, note: { _ in })
    }

    @Test func claudesWaitingTabIsToldAtOnceAndCanBeLoadedOver() async throws {
        let fake = FakeSafariTabs()
        let b = tabBrowser(fake)
        _ = try await b.open("https://shop.example.com/", newTab: false)
        fake.windows[0].tabs[2].waiting = true
        await #expect(throws: SafariBrowser.Failure.dialogWaiting(owners: false)) { _ = try await b.read(offset: 0) }
        #expect(BrowserCapability.explain(.dialogWaiting(owners: false)).contains("Opening a page"))
        // Loading over it works: the tab is known by its address while its page waits.
        _ = try await b.open("https://shop.example.com/other", newTab: false)
        #expect(fake.windows[0].tabs[2].url == "https://shop.example.com/other")
        #expect(fake.ownerTabs.map(\.url) == ["https://mail.example.com/", "https://news.example.com/"])
    }

    @Test func whatTheDialogsSaidComesWithTheAnswer() async throws {
        let fake = FakeSafariTabs()
        let b = tabBrowser(fake)
        _ = try await b.open("https://shop.example.com/", newTab: false)
        fake.dialogsSaid = #"[["confirm","Delete the order?","ok"]]"#
        await b.answering(DialogAnswer(confirm: true))
        _ = try await b.read(offset: 0)
        #expect(await b.takeDialogs() == ["The page asked to confirm: «Delete the order?»; Latchkey answered OK."])
        let sent = fake.scripts.indices.last { fake.scripts[$0] == SafariBrowser.Script.tabJavaScript }
        #expect(sent.map { fake.calls[$0].args[5].contains("ok = true") } == true, "Claude's OK went into the page")
    }

    @Test func browserActTakesConfirmAndPromptText() throws {
        #expect(try BrowserCapability.answer(.object(["confirm": .bool(true)])) == DialogAnswer(confirm: true))
        #expect(try BrowserCapability.answer(.object(["prompt_text": .string("Toni")])) == DialogAnswer(text: "Toni"))
        #expect(throws: ArgumentError.self) { try BrowserCapability.answer(.object(["confirm": .string("yes")])) }
    }

    @Test func claudesOwnWindowTellsAWaitingPage() async throws {
        let fake = FakeSafari()
        let b = SafariBrowser(scripts: fake, place: { .window })
        _ = try await b.open("https://shop.example.com/", newTab: false)
        fake.dialogWaiting = true
        await #expect(throws: SafariBrowser.Failure.dialogWaiting(owners: false)) { _ = try await b.read(offset: 0) }
    }
}
