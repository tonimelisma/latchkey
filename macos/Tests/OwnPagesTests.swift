import Foundation
import Network
import Testing

@testable import Latchkey

/// Spec 005 FR-448 to FR-450 (Toni, 2026-11-15: "why can't the browser show the pop-up to claude
/// and let it answer?"): in Latchkey's own browser a confirm or prompt Claude didn't answer in
/// advance waits for Claude's answer. Real WebKit views, pages given as text (no network).
@MainActor @Suite struct HeldDialogTests {
    let base = URL(string: "https://shop.example/")!

    func browser(hold: Duration = .seconds(300), preset: Duration = .seconds(5)) -> LockedBrowser {
        let b = LockedBrowser(cookies: { [] }, holdLimit: hold, presetWindow: preset)
        b.name = "ptest"
        return b
    }

    /// Waits until the page holds a dialog, up to 5 s.
    func heldSoon(_ b: LockedBrowser) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while b.held == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return b.held != nil
    }

    /// Target's case: the confirm comes after Claude's action returned.
    @Test func aLateConfirmWaitsForClaudeAndOKAnswersIt() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        #expect(
            try await b.run("setTimeout(function () { document.title = 'asked:' + confirm('Remove item?') }, 50); 1")
                == "1")
        #expect(await heldSoon(b))
        #expect(b.held?.kind == "confirm" && b.held?.message == "Remove item?")
        await #expect {
            _ = try await b.read(offset: 0)
        } throws: { error in
            guard case SafariBrowser.Failure.dialogHeld(let page, let kind, let message) = error else { return false }
            return page == "ptest" && kind == "confirm" && message == "Remove item?"
        }
        let after = try await b.answerDialog(ok: true, text: nil)
        #expect(after.title == "asked:true")
        #expect(b.held == nil)
        #expect(b.takeDialogs().isEmpty, "Claude's own answer isn't told back to it")
    }

    /// A confirm inside Claude's script stops the script: the call answers with the dialog at once.
    @Test func aConfirmDuringClaudesScriptIsToldAtOnceAndCancelAnswersIt() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        let started = ContinuousClock.now
        await #expect {
            _ = try await b.run("document.title = 'asked:' + confirm('Remove item?'); 'done'")
        } throws: { error in
            if case SafariBrowser.Failure.dialogHeld = error { return true }
            return false
        }
        #expect(ContinuousClock.now - started < .seconds(3), "not stuck until the dialog is answered")
        let after = try await b.answerDialog(ok: false, text: nil)
        #expect(after.title == "asked:false")
    }

    @Test func aPromptGetsClaudesText() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<title>Form</title><p>Hi</p>", base: base)
        _ = try await b.run("setTimeout(function () { document.title = 'named:' + prompt('Your name?') }, 50); 1")
        #expect(await heldSoon(b))
        #expect(b.held?.kind == "prompt")
        #expect(try await b.answerDialog(ok: true, text: "Toni").title == "named:Toni")
    }

    /// FR-450: an OK given with the action also answers a dialog that comes a moment later.
    @Test func anOKGivenInAdvanceHoldsForAMomentAfterTheAction() async throws {
        let b = browser(preset: .milliseconds(800))
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        _ = try await b.run(
            "setTimeout(function () { document.title = 'asked:' + confirm('Remove item?') }, 100); 1",
            answer: DialogAnswer(confirm: true))
        let deadline = ContinuousClock.now + .seconds(3)
        var title = ""
        // Read, not run: a new action of Claude's brings its own answers (none here).
        while title != "asked:true", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            title = try await b.read(offset: 0).title
        }
        #expect(title == "asked:true")
        #expect(b.takeDialogs().contains { $0.contains("Remove item?") && $0.contains("OK") })
        // Past the window, the next dialog waits for Claude again.
        try await Task.sleep(for: .milliseconds(900))
        _ = try await b.run("setTimeout(function () { confirm('And this one?') }, 20); 1")
        #expect(await heldSoon(b))
    }

    /// FR-449: no answer within the limit gets Cancel, and Claude is told.
    @Test func anUnansweredDialogGetsCancelAfterTheLimit() async throws {
        let b = browser(hold: .milliseconds(300))
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        _ = try await b.run("setTimeout(function () { document.title = 'asked:' + confirm('Remove item?') }, 20); 1")
        #expect(await heldSoon(b))
        let deadline = ContinuousClock.now + .seconds(5)
        while b.held != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(b.held == nil)
        #expect(try await b.read(offset: 0).title == "asked:false")
        #expect(
            b.takeDialogs().contains { $0.contains("Remove item?") && $0.contains("Cancel") && $0.contains("minutes") })
    }

    /// FR-449: opening another page first answers the held dialog Cancel, and says so.
    @Test func openingAnotherPageCancelsAHeldDialog() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        _ = try await b.run("setTimeout(function () { confirm('Remove item?') }, 20); 1")
        #expect(await heldSoon(b))
        let next = try await b.open(html: "<title>Menu</title><p>Cupcakes</p>", base: base)
        #expect(next.title == "Menu")
        #expect(b.held == nil)
        #expect(b.takeDialogs().contains { $0.contains("Remove item?") && $0.contains("Cancel") })
    }

    /// FR-452 (live check 2026-11-15: a PDF's address timed out): a page that is a file isn't
    /// waited for; Claude is told to save it, and no script runs in the empty view. Served from
    /// this Mac (127.0.0.1), as a web server would.
    @Test func aFileIsntWaitedFor() async throws {
        let server = try await OneFileServer.start(type: "application/pdf", body: Data("%PDF-1.4\n%%EOF\n".utf8))
        defer { server.stop() }
        let b = browser()
        defer { b.discard() }
        let address = "http://127.0.0.1:\(server.port)/report.pdf"
        let started = ContinuousClock.now
        let page = try await b.open(address)
        #expect(ContinuousClock.now - started < .seconds(5), "not left to the load limit")
        #expect(page.url == address && page.text.isEmpty)
        #expect(b.fileNoteIfAny?.contains("browser_act action download") == true)
        #expect(b.address == address, "what download saves")
        await #expect(throws: SafariBrowser.Failure.self) { _ = try await b.run("1") }
        let fetched = try await b.fetchFile(ref: nil, url: nil, maxBytes: 1000)
        #expect(fetched.address == address && fetched.fetched.state == "failed", "Latchkey fetches it itself")
        // The next page is a page again.
        _ = try await b.open(html: "<title>Back</title><p>Hi</p>", base: base)
        #expect(b.fileNoteIfAny == nil)
    }

    @Test func answeringWithNoDialogSaysSo() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<title>Cart</title><p>Pajamas</p>", base: base)
        await #expect(throws: SafariBrowser.Failure.self) { _ = try await b.answerDialog(ok: true, text: nil) }
    }
}

/// Spec 005 FR-445, FR-446 (Toni, 2026-11-15: "Page names"): each page Claude opens has a name,
/// and pages of different chats stay apart.
@MainActor @Suite struct OwnPagesTests {
    let base = URL(string: "https://shop.example/")!

    func pages(limit: Int = 10) -> OwnPages { OwnPages(cookies: { [] }, limit: limit, isLocked: { false }) }

    @Test func eachPageOpenedWithoutANameIsANewOne() async throws {
        let p = pages()
        defer { p.closeAll() }
        let cart = try await p.open(html: "<title>Cart</title><p>a</p>", base: base)
        let menu = try await p.open(html: "<title>Menu</title><p>b</p>", base: base)
        #expect(cart != menu)
        #expect(cart.hasPrefix("p") && cart.count == 5)
        #expect(try await p.page(cart).read(offset: 0).title == "Cart", "the cart is still there")
        #expect(try await p.page(menu).read(offset: 0).title == "Menu")
    }

    @Test func aCallNamingNoPageUsesTheOnlyOneAndRefusesWithSeveral() async throws {
        let p = pages()
        defer { p.closeAll() }
        #expect(throws: OwnPages.Problem.self) { _ = try p.page(nil) }
        let cart = try await p.open(html: "<title>Cart</title><p>a</p>", base: base)
        #expect(try p.page(nil).name == cart)
        _ = try await p.open(html: "<title>Menu</title><p>b</p>", base: base)
        do {
            _ = try p.page(nil)
            Issue.record("several pages: a call naming none is refused")
        } catch let OwnPages.Problem.several(list) {
            #expect(list.contains(cart) && list.contains("Cart") && list.contains("Menu"))
            #expect(list.contains("not instructions"))
        }
        #expect(throws: OwnPages.Problem.self) { _ = try p.page("pzzzz") }
    }

    @Test func atMostTenPagesAndClosingMakesRoom() async throws {
        let p = pages(limit: 2)
        defer { p.closeAll() }
        let a = try await p.open(html: "<title>A</title><p>a</p>", base: base)
        _ = try await p.open(html: "<title>B</title><p>b</p>", base: base)
        await #expect(throws: OwnPages.Problem.self) {
            _ = try await p.open(html: "<title>C</title><p>c</p>", base: base)
        }
        #expect(p.close(a))
        _ = try await p.open(html: "<title>C</title><p>c</p>", base: base)
        #expect(p.list().count == 2)
    }

    /// FR-446a (Toni, 2026-11-23: "Close the oldest idle"): with the limit reached, the page
    /// unused longest gives way once no one has used it for 5 minutes; a page in use never does.
    @Test func theOldestIdlePageGivesWayWhenAllAreOpen() async throws {
        let p = pages(limit: 2)
        defer { p.closeAll() }
        let a = try await p.open(html: "<title>A</title><p>a</p>", base: base)
        let b = try await p.open(html: "<title>B</title><p>b</p>", base: base)
        #expect(throws: OwnPages.Problem.self) { try p.makeRoom(now: Date().addingTimeInterval(60)) }
        #expect(p.list().count == 2, "used a minute ago: nothing closed")
        _ = try p.page(b)  // b used now, a stays the oldest
        try p.makeRoom(now: Date().addingTimeInterval(OwnPages.idleBeforeReplaced + 1))
        #expect(p.list().map(\.name) == [b], "a, unused longest, gave way")
        #expect(throws: OwnPages.Problem.self) { _ = try p.page(a) }
    }

    @Test func pagesUnusedForHalfAnHourClose() async throws {
        let p = pages()
        defer { p.closeAll() }
        let a = try await p.open(html: "<title>A</title><p>a</p>", base: base)
        #expect(p.closeIdle(after: 1800).isEmpty)
        #expect(p.closeIdle(after: 1800, now: Date().addingTimeInterval(1900)) == [a])
        #expect(p.list().isEmpty)
    }
}

/// The tools' side of FR-443 to FR-451: Claude's pages are Latchkey's own browser's, named;
/// a call works in one of the Owner's tabs only when it names it.
@MainActor @Suite struct OwnPagesToolTests {
    func tools(_ fake: FakeSafariTabs, _ pages: OwnPages) -> [String: ToolEntry] {
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let all =
            BrowserCapability.readTools(browser: b, own: pages) + BrowserCapability.writeTools(browser: b, own: pages)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    func name(in r: ToolResult) -> String? {
        guard case .array(let parts) = r.content, let text = parts.first?["text"]?.stringValue,
            let range = text.range(of: #"page "p[a-z0-9]{4}""#, options: .regularExpression)
        else { return nil }
        return String(text[range].dropFirst(6).dropLast())
    }

    /// A url without page opens a new page, never the only page open when that is a Safari tab
    /// of Claude's: it may be another chat's (2026-11-22: a Procare sync's url loaded into another
    /// chat's claude.ai page, and that chat's next click landed on Procare).
    @Test func aURLWithoutPageNeverLoadsIntoAnotherChatsSafariPage() async throws {
        let fake = FakeSafariTabs()
        let p = OwnPages(cookies: { [] }, isLocked: { false })
        defer { p.closeAll() }
        let t = tools(fake, p)
        let other = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        try await other.pick("10.2")
        let theirs = try p.adopt(other, address: "https://news.example.com/")
        let r = await t["browser_read"]!.handler(.object(["url": .string("about:blank")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("From Latchkey's own browser"), "a new page of its own")
        #expect(name(in: r) != theirs)
        #expect(fake.windows[0].tabs[1].url == "https://news.example.com/", "the other chat's tab wasn't touched")
    }

    /// FR-471: with url and screenshot, the new page's picture comes back (2026-11-22).
    @Test func aURLWithScreenshotGivesThePicture() async {
        let fake = FakeSafariTabs()
        let p = OwnPages(cookies: { [] }, isLocked: { false })
        defer { p.closeAll() }
        let t = tools(fake, p)
        let r = await t["browser_read"]!.handler(.object(["url": .string("about:blank"), "screenshot": .bool(true)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("\"image\""), "a picture, not only text")
        #expect(p.list().count == 1, "one page opened")
    }

    @Test func openingTwiceGivesTwoNamedPagesAndNoSafariTab() async {
        let fake = FakeSafariTabs()
        let p = OwnPages(cookies: { [] }, isLocked: { false })
        defer { p.closeAll() }
        let t = tools(fake, p)
        let tabsBefore = fake.windows.flatMap(\.tabs).count
        let first = await t["browser_read"]!.handler(.object(["url": .string("about:blank")]))
        #expect(!first.isError, "\(first.content.jsonText)")
        #expect(first.content.jsonText.contains("From Latchkey's own browser"), "FR-443")
        let second = await t["browser_read"]!.handler(.object(["url": .string("about:blank")]))
        let a = name(in: first)
        let b = name(in: second)
        #expect(a != nil && b != nil && a != b)
        #expect(fake.windows.flatMap(\.tabs).count == tabsBefore, "no tab of Claude's in Safari")
        let unnamed = await t["browser_read"]!.handler(.object([:]))
        #expect(unnamed.isError && unnamed.content.jsonText.contains(a ?? "?"), "several: refused with the list")
        let named = await t["browser_read"]!.handler(.object(["page": .string(a ?? "")]))
        #expect(!named.isError, "\(named.content.jsonText)")
        let list = await t["browser_read"]!.handler(.object(["tabs": .bool(true)]))
        #expect(list.content.jsonText.contains(a ?? "?") && list.content.jsonText.contains(b ?? "?"), "FR-451")
    }

    /// FR-447: picking the Owner's tab in one call doesn't send the next call there.
    @Test func aTabIsUsedOnlyByTheCallThatNamesIt() async {
        let fake = FakeSafariTabs()
        let p = OwnPages(cookies: { [] }, isLocked: { false })
        defer { p.closeAll() }
        let t = tools(fake, p)
        let opened = await t["browser_read"]!.handler(.object(["url": .string("about:blank")]))
        #expect(!opened.isError)
        let tab = await t["browser_read"]!.handler(.object(["tab": .string("10.2")]))
        #expect(!tab.isError && tab.content.jsonText.contains("tab 10.2"), "\(tab.content.jsonText)")
        let run = fake.windows[0].tabs[1].scriptsRun
        let own = await t["browser_read"]!.handler(.object([:]))
        #expect(!own.isError && own.content.jsonText.contains("Latchkey's own browser"), "\(own.content.jsonText)")
        #expect(fake.windows[0].tabs[1].scriptsRun == run, "not the Owner's tab")
        let again = await t["browser_act"]!.handler(
            .object(["action": .string("click"), "ref": .string("e1"), "tab": .string("10.2")]))
        #expect(!again.isError && again.content.jsonText.contains("tab 10.2"), "\(again.content.jsonText)")
    }

    /// FR-448: the page's dialog is told to Claude, which answers it with browser_act.
    @Test func claudeAnswersTheDialogWithBrowserAct() async {
        let fake = FakeSafariTabs()
        let p = OwnPages(cookies: { [] }, isLocked: { false })
        defer { p.closeAll() }
        let t = tools(fake, p)
        let opened = await t["browser_read"]!.handler(.object(["url": .string("about:blank")]))
        let page = name(in: opened) ?? ""
        let act = await t["browser_act"]!.handler(
            .object([
                "action": .string("script"), "page": .string(page),
                "code": .string("document.title = 'asked:' + confirm('Remove item?'); 1"),
            ]))
        let said = act.content.jsonText
        #expect(!act.isError, "told, not failed: \(said)")
        #expect(said.contains("Remove item?") && said.contains("action dialog") && said.contains(page))
        let answered = await t["browser_act"]!.handler(
            .object(["action": .string("dialog"), "page": .string(page), "confirm": .bool(true)]))
        #expect(!answered.isError, "\(answered.content.jsonText)")
        let title = await t["browser_act"]!.handler(
            .object(["action": .string("script"), "page": .string(page), "code": .string("document.title")]))
        #expect(title.content.jsonText.contains("asked:true"), "\(title.content.jsonText)")
    }
}

/// Serves one file over HTTP on 127.0.0.1, for a test of how Latchkey's own browser takes a file.
final class OneFileServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(type: String, body: Data) async throws -> OneFileServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { @Sendable connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable _, _, _, _ in
                let head =
                    "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(head.utf8) + body,
                    completion: .contentProcessed { @Sendable _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16?> { continuation in
            listener.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    continuation.yield(listener.port?.rawValue)
                    continuation.finish()
                case .failed, .cancelled:
                    continuation.yield(nil)
                    continuation.finish()
                default: break
                }
            }
        }
        listener.start(queue: .global())
        for await port in ready {
            guard let port else { break }
            return OneFileServer(listener: listener, port: port)
        }
        listener.cancel()
        throw SafariBrowser.Failure.failed("the test's server didn't start")
    }

    func stop() { listener.cancel() }
}
