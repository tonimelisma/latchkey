import Foundation
import Network
import Testing
import WebKit

@testable import Latchkey

/// Regression cases of the group regressions-browser (second half), each tested where
/// Latchkey's own code decides it (`macos/scripts/state-check/cases.json`). Real WebKit views
/// with pages given as text or served from this Mac (127.0.0.1); the stand-in Safari for the
/// owner's tabs. No site on the network is reached.

/// regressions.browser_busy_tab_not_called_dialog (2026-11-15): an idle Safari took 12 s to
/// answer its first script, and a busy tab of the owner's was told to Claude as waiting on a
/// dialog. The check of a tab waits 10 s (not 6), and the answer says first that the tab is most
/// often busy or paused, a dialog only maybe.
@Suite struct RegressionBusyTabCTests {
    @Test func theTabChecksWaitTenSecondsBeforeCallingATabWaiting() {
        for script in [SafariBrowser.Script.tabSurvey, SafariBrowser.Script.tabPick] {
            #expect(script.contains("with timeout of 10 seconds"))
            #expect(!script.contains("with timeout of 6 seconds") && !script.contains("with timeout of 2 seconds"))
        }
    }

    @Test func aTabThatDidntAnswerIsSaidBusyFirstADialogOnlyMaybe() throws {
        let said = BrowserCapability.explain(.dialogWaiting)
        #expect(said.contains("within 10 seconds"), "\(said)")
        let busy = try #require(said.range(of: "busy"))
        let dialog = try #require(said.range(of: "dialog"))
        #expect(busy.lowerBound < dialog.lowerBound, "busy or paused comes first: \(said)")
        #expect(said.contains("try again") && said.contains("may be waiting on a dialog"))
    }
}

/// regressions.browser_close_spares_owner_tabs (2026-11-15: an agent closed the owner's LinkedIn
/// tab) and regressions.browser_locked_close_names_own_browser (2026-11-07: closing while
/// locked said Safari): browser_act close with Claude's page closes that page only, touches no
/// Safari tab, and names Latchkey's own browser, locked or not.
@MainActor @Suite struct RegressionCloseCTests {
    func act(_ fake: FakeSafariTabs, _ own: OwnPages) -> ToolEntry {
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        return BrowserCapability.writeTools(browser: b, own: own).first { $0.tool.name == "browser_act" }!
    }

    @Test(arguments: [true, false])
    func closingClaudesPageClosesOnlyItAndNamesLatchkeysOwnBrowser(_ locked: Bool) async throws {
        let fake = FakeSafariTabs(userTabs: ["https://www.linkedin.com/feed/", "https://news.example.com/"])
        let own = OwnPages(cookies: { [] }, isLocked: { locked }, record: { _ in })
        defer { own.closeAll() }
        let base = URL(string: "https://example.com/")!
        let mine = try await own.open(html: "<title>Example Domain</title><p>Example Domain</p>", base: base)
        let other = try await own.open(html: "<title>Other</title><p>Another chat's page</p>", base: base)
        let tabsBefore = fake.ownerTabs.map(\.url)
        let r = await act(fake, own).handler(.object(["action": .string("close"), "page": .string(mine)]))
        let text = r.plainText
        #expect(!r.isError, "\(text)")
        #expect(text.contains("Latchkey's own browser"), "\(text)")
        #expect(!text.contains("Safari"), "never said to be Safari's: \(text)")
        #expect(fake.ownerTabs.map(\.url) == tabsBefore, "every owner's tab is still there")
        #expect(!fake.scripts.contains(SafariBrowser.Script.tabClose), "no Safari tab was closed")
        #expect(own.list().map(\.name) == [other], "only Claude's page is gone")
    }
}

/// Serves the start of a page from this Mac and never the rest: the page goes on loading for
/// as long as the test lasts (bugzilla.samba.org was such a slow site, 2026-11-15).
final class HangingServerC: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var held: [NWConnection] = []

    private init(listener: NWListener) { self.listener = listener }

    private func hold(_ c: NWConnection) { lock.withLock { held.append(c) } }

    static func start(start body: Data, promised: Int) async throws -> HangingServerC {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = HangingServerC(listener: try NWListener(using: params))
        let listener = server.listener
        listener.newConnectionHandler = { @Sendable connection in
            server.hold(connection)
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable _, _, _, _ in
                let head =
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(promised)\r\n\r\n"
                // The rest of what the length promises never comes; the connection stays open.
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { @Sendable _ in })
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
            server.port = port
            return server
        }
        listener.cancel()
        throw SafariBrowser.Failure.failed("the test's server didn't start")
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            held.forEach { $0.cancel() }
            held = []
        }
    }
}

/// Pages of Latchkey's own browser that don't load as hoped.
@MainActor @Suite struct RegressionLoadingCTests {
    func browser() -> LockedBrowser {
        let b = LockedBrowser(cookies: { [] })
        b.name = "pcase"
        return b
    }

    /// regressions.browser_slow_site_no_lost_page: a slow site answered "didn't answer within 30
    /// seconds", the next read "page isn't open", and later (2026-11-16) an empty page with no word
    /// why. The page answers within the relay's 30 s, says it is still loading and how to read
    /// it again, and is still there to read.
    @Test func aSlowPageAnswersInTimeSaysItIsStillLoadingAndStaysOpen() async throws {
        #expect(LockedBrowser.loadLimit < .seconds(25), "the load's limit leaves time within the relay's 30 s")
        let start = Data(
            ("<!DOCTYPE html><html><head><title>Slow</title></head><body><!-- "
                + String(repeating: "padding ", count: 600) + " -->").utf8)
        let server = try await HangingServerC.start(start: start, promised: 1_000_000)
        defer { server.stop() }
        let b = browser()
        defer { b.discard() }
        let address = "http://127.0.0.1:\(server.port)/createaccount.cgi"
        let started = ContinuousClock.now
        let page = try await b.open(address)
        // The load limit is 20 s; GitHub's runner is slower than any Mac, so the bound here only
        // catches an answer that never comes. The fix is the answer's words and the page kept.
        #expect(ContinuousClock.now - started < .seconds(90), "an answer, not a wait for the whole page")
        #expect(page.text.contains("still loading") && page.text.contains("browser_look"), "\(page.text)")
        let again = try await b.read(offset: 0)
        #expect(again.url == address, "the same page, still open")
    }

    /// regressions.browser_failed_load_not_old_page (2026-10-25): a page that didn't load was
    /// answered with the old page's text. Now it is an error saying the page didn't load.
    @Test func aPageThatDoesntLoadIsAnErrorNotTheOldPage() async throws {
        // A port nothing listens on any more: the connection is refused at once.
        let gone = try await OneFileServer.start(type: "text/plain", body: Data("x".utf8))
        let port = gone.port
        gone.stop()
        try await Task.sleep(for: .milliseconds(200))
        let b = browser()
        defer { b.discard() }
        let first = try await b.open(
            html: "<title>Example Domain</title><p>Example Domain</p>", base: URL(string: "https://example.com/")!)
        #expect(first.text.contains("Example Domain"))
        do {
            let p = try await b.open("http://127.0.0.1:\(port)/")
            Issue.record("answered with a page: \(p.title) \(p.text)")
        } catch SafariBrowser.Failure.failed(let message) {
            #expect(message.contains("didn't load"), "\(message)")
            #expect(!message.contains("Example Domain"))
        }
    }

    /// regressions.browser_back_no_cancel_error (app 0.8.78, 2026-11-02): going back answered
    /// "page didn't load, NSURLErrorDomain -999" though the page went back. WebKit's cancelled
    /// load is no failure: back answers with the page. (Whether WebKit cancels a load on a given
    /// back is its own; the locked run is the owner's.)
    @Test func goingBackAnswersWithThePageAndNoCancelError() async throws {
        let html = """
            <!DOCTYPE html><html><head><title>Example Domain</title></head><body>
            <h1>Example Domain</h1><p><a href="/more">More information...</a></p></body></html>
            """
        let server = try await OneFileServer.start(type: "text/html; charset=utf-8", body: Data(html.utf8))
        defer { server.stop() }
        let b = browser()
        defer { b.discard() }
        let first = "http://127.0.0.1:\(server.port)/first"
        var opened = try await b.open(first)
        // GitHub's runner can answer before the page has drawn (it is still loading): read again.
        let drawn = ContinuousClock.now + .seconds(60)
        while !opened.elements.contains(where: { $0.label.contains("More information") }), ContinuousClock.now < drawn {
            try await Task.sleep(for: .milliseconds(500))
            opened = try await b.read(offset: 0)
        }
        let more = try #require(opened.elements.first { $0.label.contains("More information") }?.ref, "\(opened.text)")
        let clicked = try await b.click(more)
        #expect(clicked.url.hasSuffix("/more"), "\(clicked.url)")
        let back = try await b.back()
        #expect(back.url == first, "\(back.url)")
        #expect(back.text.contains("Example Domain"))
        #expect(!back.text.contains("-999"))
    }
}

/// regressions.browser_owner_tab_turns (2026-11-19): another chat's pick came between this
/// chat's pick and its click, so the click ran in another chat's tab. A call naming an owner's
/// tab waits for the turn another call holds, and does nothing to the tab until then.
@MainActor @Suite struct RegressionOwnerTabTurnsCTests {
    @Test func aCallNamingAnOwnersTabWaitsForTheOtherCallsTurn() async throws {
        let fake = FakeSafariTabs()
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        defer { own.closeAll() }
        let read = try #require(
            BrowserCapability.readTools(browser: b, own: own).first { $0.tool.name == "browser_look" })
        #expect(await b.turns.enter(within: .seconds(1)), "another chat's turn")
        let call = Task { await read.handler(.object(["tab": .string("10.2")])) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(fake.windows[0].tabs[1].picks == 0, "not picked while the other turn lasts")
        #expect(fake.windows[0].tabs[1].scriptsRun == 0, "nothing ran in the tab while the other turn lasts")
        await b.turns.leave()
        let r = await call.value
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("tab 10.2"), "it read the tab it named: \(r.plainText)")
    }

    @Test func aTurnThatDoesntComeSaysAnotherChatIsWorking() async throws {
        let fake = FakeSafariTabs()
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        defer { own.closeAll() }
        let read = try #require(
            BrowserCapability.readTools(browser: b, own: own).first { $0.tool.name == "browser_look" })
        #expect(await b.turns.enter(within: .seconds(1)))
        let r = await read.handler(.object(["tab": .string("10.1")]))
        await b.turns.leave()
        #expect(r.isError && r.plainText.contains("Another chat"), "\(r.plainText)")
        #expect(fake.windows[0].tabs[0].scriptsRun == 0 && fake.windows[0].tabs[0].picks == 0, "nothing was done")
    }
}

/// regressions.browser_safari_script_await_and_iife (2026-11-22/23): in Claude's Safari tabs a
/// script with await or several statements failed with "The variable theAnswer is not defined
/// (-2753)", and a page that replaced eval refused every script ("eval is disabled", Amex).
@Suite struct RegressionSafariScriptCTests {
    /// Safari's scripts never go through the page's eval, so a page that replaced it can't
    /// refuse them.
    @Test func safarisScriptsNeverUseThePagesEval() async throws {
        let fake = FakeSafariTabs()
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        try await b.pick("10.2")
        #expect(try await b.run("1 + 1") == "ok")
        let sent = fake.calls.filter { $0.script == SafariBrowser.Script.tabJavaScript }
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { !$0.args.joined().contains("(0, eval)") }, "the page's eval was used")
    }

    /// A script whose value is undefined leaves AppleScript's result unset: it is read as empty.
    @Test func anUndefinedResultIsReadAsEmpty() {
        #expect(
            SafariBrowser.Script.tabJavaScript.contains("try\ntheAnswer\non error\nset theAnswer to \"\"\nend try"))
    }

    /// The scripts Safari runs work in a real page whose eval throws.
    @MainActor @Test func theAsyncRouteRunsWhereThePageReplacedEval() async throws {
        let p = TestPage()
        // In a window that never comes on screen, as Latchkey's own browser keeps its pages: on
        // GitHub's runner a view without one didn't finish loading within 30 s.
        let holder = LockedBrowser.holder(for: p.view)
        defer {
            holder.contentView = nil
            holder.close()
        }
        try await p.load(
            """
            <html><head><title>Amex</title><script>
            window.eval = function () { throw new Error('eval is disabled'); };
            </script></head><body><p>Hi</p></body></html>
            """)
        func run(_ code: String) async throws -> String {
            let id = UUID().uuidString
            let body = try #require(PageScripts.asyncBodies(code).first)
            #expect(try await p.run(PageScripts.startAsync(id: id, body: body)) == "started")
            for _ in 0..<100 {
                let r = try await p.run(PageScripts.asyncResult(id: id))
                if r != "running" { return r }
                try await Task.sleep(for: .milliseconds(20))
            }
            return "still running"
        }
        #expect(
            try await run("const t = await Promise.resolve(document.title);\nt.length")
                == #"{"state":"done","value":"4"}"#)
        #expect(
            try await run("(async () => { await 0; return document.title })()")
                == #"{"state":"done","value":"Amex"}"#)
    }

    /// Latchkey's own browser too: a page that replaced eval still runs Claude's scripts.
    @MainActor @Test func latchkeysOwnBrowserRunsWhereThePageReplacedEval() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        _ = try await b.open(
            html: "<title>Amex</title><script>window.eval = function () { throw new Error('eval is disabled'); };"
                + "</script><p>Hi</p>",
            base: URL(string: "https://www.americanexpress.test/")!)
        #expect(try await b.run("document.title") == "Amex")
        #expect(try await b.run("const t = await Promise.resolve(document.title);\nt.length") == "4")
        #expect(try await b.run("(async () => { await 0; return document.title })()") == "Amex")
    }
}

/// regressions.browser_type_submit_rich_editor (2026-11-23): type with submit into claude.ai's
/// prompt box emptied it and sent nothing: text set directly was dropped by its editor, which
/// keeps its own copy from typing's input events and sends that on Enter.
@MainActor @Suite struct RegressionRichEditorCTests {
    @Test func typingWithSubmitIntoARichEditorSendsTheText() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let html = """
            <html><head><title>Editor</title></head><body>
            <div id="ed" contenteditable="true" aria-label="Write your prompt" style="min-height:40px"></div>
            <script>
            var model = '', ed = document.getElementById('ed');
            // The editor's own copy changes only with typing (an input event of typing's kind).
            ed.addEventListener('input', function (ev) {
              if (ev.inputType === 'insertText' || ev.inputType === 'insertReplacementText') model = ed.textContent;
            });
            ed.addEventListener('keydown', function (ev) {
              if (ev.key === 'Enter') { ev.preventDefault(); document.title = 'sent:' + model; }
            });
            </script></body></html>
            """
        _ = try await b.open(html: html, base: URL(string: "https://editor.test/")!)
        _ = try await b.read(offset: 0)
        let ref = try await b.run("document.getElementById('ed').getAttribute('data-latchkey') || ''")
        try #require(!ref.isEmpty, "the editor is listed")
        _ = try await b.type(ref, text: "Helsinki", submit: true)
        #expect(try await b.run("document.title") == "sent:Helsinki")
    }
}

/// regressions.browser_hover_says_what_it_did (2026-11-22, Nike): a hover answered "nothing new
/// shows" though the menu opened a moment later and its items were in the answer's list.
@MainActor @Suite struct RegressionHoverCTests {
    @Test func aHoverWhoseMenuDrawsLateDoesntSayNothingShows() async throws {
        let fake = FakeSafariTabs()
        let own = OwnPages(cookies: { [] }, isLocked: { true }, record: { _ in })
        defer { own.closeAll() }
        let b = SafariBrowser(scripts: fake, settleLimit: .seconds(3))
        let act = BrowserCapability.writeTools(browser: b, own: own).first { $0.tool.name == "browser_act" }!
        let html = """
            <html><head><title>Shop</title></head><body>
            <div id="acct" aria-haspopup="true">Account</div><div id="menu"></div>
            <script>
            document.getElementById('acct').addEventListener('mouseenter', function () {
              setTimeout(function () {
                document.getElementById('menu').innerHTML = '<a href="#orders">Orders</a> <a href="#out">Sign out</a>';
              }, 300);
            });
            </script></body></html>
            """
        let name = try await own.open(html: html, base: URL(string: "https://www.shop.test/")!)
        let page = try await own.page(name).read(offset: 0)
        let ref = try #require(page.elements.first { $0.label.contains("Account") }?.ref)
        let r = await act.handler(.object(["action": .string("hover"), "ref": .string(ref), "page": .string(name)]))
        let text = r.plainText
        #expect(!r.isError, "\(text)")
        #expect(text.contains("Sign out"), "the menu's items are in the answer: \(text)")
        #expect(!text.contains("nothing new shows"), "\(text)")
    }
}
