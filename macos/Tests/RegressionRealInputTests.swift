import AppKit
import Foundation
import Testing

@testable import Latchkey

/// regressions-browser.browser_procare_role_choice (Procare, problem reports 2026-11-24 and
/// 2026-11-25, reproduced on 0.8.243): schools.procareconnect.com/login asks "How would you like
/// to log in? STAFF / PARENT" with two boxes (divs with a click handler on the page's root, as
/// React attaches them, and the pointing-hand cursor) that Latchkey's element list didn't show;
/// LOGIN stays disabled until one is chosen, so logins_fill's press landed on a disabled button
/// and the page came back unchanged without a word. Also seen: typing gave `input` before
/// `keydown` and no `keyup`, clicks were `isTrusted: false`, `document.hasFocus()` false.
/// Spec 005 FR-478 to FR-487, spec 013 FR-1377. Real WebKit views, pages given as text; no site
/// on the network is reached.
@MainActor @Suite struct RegressionRealInputTests {
    static let base = URL(string: "https://schools.test/login")!
    static let parent = SavedSignIn(
        title: "Procare", site: "schools.test", user: "ann@x.test", password: "pw-P!\"<9>", otp: nil)

    /// Procare's page, in the structure that mattered: the role boxes aren't controls, their
    /// handler is one listener on the root, and LOGIN is disabled until a role is chosen.
    static let procare = """
        <title>Procare</title>
        <div id="app">
          <p>How would you like to log in?</p>
          <div class="auth__role-selector">
            <div class="auth__role-selector__teacher" style="cursor:pointer;padding:20px;width:200px"><span>STAFF</span></div>
            <div class="auth__role-selector__carer" style="cursor:pointer;padding:20px;width:200px"><span>PARENT</span></div>
          </div>
          <form id="f">
            <input name="email" type="email" autocomplete="username">
            <input name="password" type="password" autocomplete="current-password">
            <button id="login" type="submit" disabled>LOGIN</button>
          </form>
        </div>
        <script>
        var role = null;
        document.getElementById('app').addEventListener('click', function (ev) {
          var t = ev.target.closest && ev.target.closest('[class*=auth__role-selector__]');
          if (!t) return;
          role = t.className.indexOf('carer') >= 0 ? 'parent' : 'staff';
          document.querySelectorAll('[class*=auth__role-selector__]').forEach(function (x) {
            x.classList.toggle('auth__role-selector--selected', x === t);
          });
          document.getElementById('login').disabled = false;
        });
        document.getElementById('f').addEventListener('submit', function (ev) {
          ev.preventDefault();
          var ok = document.querySelector('[name=email]').value === 'ann@x.test' && document.querySelector('[name=password]').value === 'pw-P!"<9>';
          document.title = 'Dashboard ' + role + ' ' + (ok ? 'ok' : 'bad');
        });
        </script>
        """

    func element(_ p: PageScripts.Page, _ label: String) -> PageScripts.Element? {
        p.elements.first { $0.label == label }
    }

    @Test func theRoleChoiceIsListedClickedForRealAndTheSignInGoesThrough() async throws {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [Self.parent], at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        defer { own.closeAll() }
        let fill = LoginsCapability.fill(store: s, own: own)
        let name = try await own.open(html: Self.procare, base: Self.base)
        let b = try own.page(name)
        let first = try await b.read(offset: 0)
        let choice = try #require(element(first, "PARENT"), "the role box is listed: \(first.elements)")
        #expect(choice.kind == "clickable")
        #expect(element(first, "STAFF")?.kind == "clickable")
        #expect(first.elements.filter { $0.label == "PARENT" }.count == 1, "the box, not also its text inside")
        let after = try await b.click(choice.ref)
        #expect(element(after, "PARENT")?.state == "selected", "its state shows: \(after.elements)")
        #expect(try await b.run("String(document.getElementById('login').disabled)") == "false")
        let user = try #require(after.elements.first { $0.kind == "field:email" })
        let pw = try #require(after.elements.first { $0.kind == "field:password" })
        let login = try #require(element(after, "LOGIN"))
        func call(_ a: [String: JSONValue]) async -> ToolResult {
            var args = a
            args["page"] = .string(name)
            return await fill.handler(.object(args))
        }
        let u = await call(["field": .string(user.ref), "fill": .string("user")])
        #expect(!u.isError, "\(u.plainText)")
        let r = await call(["field": .string(pw.ref), "fill": .string("password"), "press": .string(login.ref)])
        #expect(!r.isError, "\(r.plainText)")
        #expect(!r.plainText.contains(Self.parent.password), "never shown")
        #expect(try await b.run("document.title") == "Dashboard parent ok")
        #expect(try await b.run("document.querySelector('[name=password]').value") == "", "emptied after")
    }

    /// What the page hears: trusted events in a keyboard's and a mouse's order, the page focused
    /// during Claude's call and not after (FR-478, FR-480, FR-483).
    static let listening = """
        <title>Events</title>
        <input id="f" data-latchkey="e1" type="text">
        <button id="b" data-latchkey="e2" style="width:120px;height:40px">Go</button>
        <script>
        window.log = [];
        ['keydown', 'keypress', 'beforeinput', 'input', 'keyup', 'focus'].forEach(function (k) {
          document.getElementById('f').addEventListener(k, function (ev) { log.push(k + ':' + ev.isTrusted); });
        });
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (k) {
          document.getElementById('b').addEventListener(k, function (ev) { log.push(k + ':' + ev.isTrusted + ':' + document.hasFocus()); });
        });
        </script>
        """

    @Test func typingAndClickingAreAKeyboardsAndAMousesInTheirOrder() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        _ = try await b.open(html: Self.listening, base: Self.base)
        _ = try await b.type("e1", text: "aB", submit: false)
        #expect(try await b.run("document.getElementById('f').value") == "aB")
        let typed = try await b.run("log.filter(function (x) { return !/^focus/.test(x); }).join(' ')")
        let one = "keydown:true keypress:true beforeinput:true input:true keyup:true"
        #expect(typed == one + " " + one, "per character, trusted, in order: \(typed)")
        #expect(try await b.run("String(log.indexOf('focus:true') === 0)") == "true", "the click put the focus there")
        _ = try await b.run("log = []")
        _ = try await b.click("e2")
        // The field that had the focus gets it back as the window comes to the front: left out.
        let clicked = try await b.run("log.filter(function (x) { return !/^focus/.test(x); }).join(' ')")
        #expect(
            clicked
                == "pointerdown:true:true mousedown:true:true pointerup:true:true mouseup:true:true click:true:true",
            "\(clicked)")
        #expect(try await b.run("String(document.hasFocus())") == "false", "behind other windows between calls")
    }

    /// FR-480: a character no US key types arrives as text; Enter submits.
    @Test func aCharacterNoKeyTypesArrivesAsTextAndSubmitPressesEnter() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let page = """
            <form id="f" onsubmit="event.preventDefault(); document.title = 'sent ' + document.getElementById('q').value">
            <input id="q" data-latchkey="e1" value="old"></form>
            """
        _ = try await b.open(html: page, base: Self.base)
        _ = try await b.type("e1", text: "Café", submit: true)
        let seen = try await b.run("document.title + ' | ' + document.getElementById('q').value")
        #expect(seen.hasPrefix("sent Café |"), "what it held was replaced, Enter sent it: \(seen)")
    }

    /// FR-484: a list, a colour field and a date field aren't clicked (a menu would hold Latchkey
    /// up, a panel would open on the owner's screen); the answer names the way that works.
    @Test func aListAColourAndADateFieldAreNotClickedAndSaySo() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let page = """
            <select data-latchkey="e1"><option>One</option><option>Two</option></select>
            <input data-latchkey="e2" type="color"><input data-latchkey="e3" type="date">
            """
        _ = try await b.open(html: page, base: Self.base)
        for (ref, word) in [("e1", "select"), ("e2", "type"), ("e3", "type")] {
            do {
                _ = try await b.click(ref)
                Issue.record("\(ref) was clicked")
            } catch {
                let said = "\(error)"
                #expect(said.contains(word), "\(ref): \(said)")
            }
        }
        _ = try await b.type("e1", text: "Two", submit: false)
        #expect(try await b.run("document.querySelector('select').value") == "Two")
        _ = try await b.type("e3", text: "2026-11-25", submit: false)
        #expect(try await b.run("document.querySelector('[type=date]').value") == "2026-11-25")
    }

    /// FR-479: an element under another one is clicked where a mouse would press: on what is on
    /// top, and the answer says what it hit.
    @Test func aCoveredElementsClickLandsOnTopAndSaysWhatItHit() async throws {
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        defer { own.closeAll() }
        let page = """
            <button data-latchkey="e1" onclick="document.title='under'" style="position:absolute;left:10px;top:10px;width:100px;height:40px">Under</button>
            <div onclick="document.title='cover'" style="position:absolute;left:0;top:0;width:300px;height:100px;background:#eee">Cookie banner</div>
            """
        let name = try await own.open(html: page, base: Self.base)
        let tool = BrowserCapability.writeTools(
            browser: SafariBrowser(scripts: FakeSafariTabs(userTabs: []), settleLimit: .seconds(3)), own: own
        ).first { $0.tool.name == "browser_act" }!
        let r = await tool.handler(
            .object(["action": .string("click"), "page": .string(name), "ref": .string("e1")]))
        #expect(!r.isError, "\(r.plainText)")
        #expect(try await own.page(name).run("document.title") == "cover")
        #expect(
            r.plainText.contains("landed on what is drawn over it") && r.plainText.contains("Cookie banner"),
            "\(r.plainText)")
    }

    /// FR-481: keys are real; Tab moves the focus as the browser does, and the answer says where.
    @Test func realKeysMoveTheFocusAndTheAnswerSaysWhere() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        _ = try await b.open(
            html:
                "<input data-latchkey=\"e1\"><input data-latchkey=\"e2\"><script>window.ups = 0; addEventListener('keyup', function (e) { if (e.isTrusted) ups++; });</script>",
            base: Self.base)
        let done = try await b.press([try PageScripts.Key("Tab")], ref: "e1")
        let now = try await b.run("(document.activeElement && document.activeElement.outerHTML) || 'none'")
        #expect(done.detail.contains("the focus is on input e2"), "\(done.detail); active: \(now)")
        #expect(try await b.run("String(ups)") == "1")
        do {
            _ = try await b.press([try PageScripts.Key("cmd+v")], ref: nil)
            Issue.record("paste was pressed")
        } catch {
            #expect("\(error)".contains("clipboard"))
        }
    }

    /// Security review 2026-11-25: a Command shortcut the page doesn't take could reach Latchkey's
    /// own menu (Cmd+Q would quit it); a click on a list's label would open its menu; a real
    /// click lets a page reach the clipboard. None of these happens.
    @Test func shortcutsPickersAndTheClipboardStayOutOfReach() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let page = """
            <label data-latchkey="e1" for="s">Size</label><select id="s"><option>S</option><option>M</option></select>
            <button data-latchkey="e2" onclick="navigator.clipboard.writeText('taken').then(function () { document.title = 'copied'; }, function () { document.title = 'refused'; }); document.execCommand('copy');">Copy</button>
            """
        _ = try await b.open(html: page, base: Self.base)
        for name in ["cmd+q", "cmd+,", "cmd+h", "cmd+w"] {
            do {
                _ = try await b.press([try PageScripts.Key(name)], ref: nil)
                Issue.record("\(name) was pressed")
            } catch {
                #expect("\(error)".contains("Command shortcuts"), "\(name): \(error)")
            }
        }
        do {
            _ = try await b.click("e1")
            Issue.record("the list's label was clicked")
        } catch {
            #expect("\(error)".contains("select"), "\(error)")
        }
        let clipboard = NSPasteboard.general.changeCount
        _ = try await b.click("e2")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await b.run("document.title") == "refused")
        #expect(NSPasteboard.general.changeCount == clipboard, "the owner's clipboard is as it was")
    }

    /// Third security review 2026-11-25: a page copies the checked field's reference onto a decoy
    /// of its own (earlier on the page, also a password box) as the click lands, and moves the
    /// focus there. Nothing of the password reaches the decoy, and nothing is pressed.
    @Test func aDecoyGivenTheFieldsReferenceGetsNoCharacter() async throws {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [Self.parent], at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        defer { own.closeAll() }
        let fill = LoginsCapability.fill(store: s, own: own)
        let page = """
            <input id="decoy" type="password" style="width:120px">
            <form onsubmit="event.preventDefault(); document.title = 'sent'">
            <input id="pw" data-latchkey="e2" type="password" autocomplete="current-password">
            <button data-latchkey="e3" type="submit">Go</button></form>
            <script>
            window.decoyGot = 0;
            var pw = document.getElementById('pw'), decoy = document.getElementById('decoy');
            decoy.addEventListener('input', function () { decoyGot++; });
            pw.addEventListener('pointerdown', function () {
              decoy.setAttribute('data-latchkey', 'e2');
              setTimeout(function () { decoy.focus(); }, 0);
            });
            </script>
            """
        let name = try await own.open(html: page, base: Self.base)
        let r = await fill.handler(
            .object([
                "page": .string(name), "field": .string("e2"), "fill": .string("password"), "press": .string("e3"),
            ]))
        #expect(r.isError, "\(r.plainText)")
        let b = try own.page(name)
        #expect(try await b.run("String(decoyGot)") == "0", "no character went into the decoy")
        #expect(try await b.run("document.title") != "sent", "nothing was pressed")
        #expect(try await b.run("document.getElementById('decoy').value + document.getElementById('pw').value") == "")
    }

    /// FR-482 (GitHub's macOS 26 runner, 2026-11-25): hover moved a pointer no page saw, because a
    /// WKWebView takes pointer moves only through its tracking area. A menu that only CSS `:hover`
    /// opens shows after Latchkey's hover, as under a mouse, and the page gets trusted moves.
    @Test func aRealHoverOpensAMenuOnlyCSSHoverShows() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let page = """
            <style>#menu ul { display: none; } #menu:hover ul { display: block; }</style>
            <div id="menu" data-latchkey="e1" style="width:200px;height:40px">Account
              <ul><li><a href="#out">Sign out</a></li></ul></div>
            <script>window.moves = 0; document.addEventListener('pointermove', function (e) { if (e.isTrusted) moves++; });</script>
            """
        _ = try await b.open(html: page, base: Self.base)
        let done = try await b.hover("e1")
        let state = try await b.run(
            "JSON.stringify({ hover: document.getElementById('menu').matches(':hover'), moves: moves })")
        #expect(done.page.elements.contains { $0.label == "Sign out" }, "the menu shows: \(state)")
        #expect(state.contains("\"moves\":") && !state.contains("\"moves\":0"), "\(state)")
    }

    /// FR-487: in the owner's Safari tabs typing stays a script, in a keyboard's order now.
    @Test func safarisScriptTypingGivesAKeyboardsOrder() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        _ = try await b.open(html: Self.listening, base: Self.base)
        // The script Safari runs, run here in the page as Safari would.
        _ = try await b.run(PageScripts.type("e1", text: "ab", submit: false))
        let typed = try await b.run("log.filter(function (x) { return !/^focus/.test(x); }).join(' ')")
        let one = "keydown:false keypress:false beforeinput:false input:false keyup:false"
        #expect(typed == one + " " + one, "\(typed)")
        #expect(try await b.run("document.getElementById('f').value") == "ab")
    }

    /// A key map for the shifted symbols a password holds.
    @Test func theUSKeyboardTypesEveryPrintableASCIICharacter() {
        for v in 32...126 {
            let ch = Character(UnicodeScalar(v)!)
            #expect(RealInput.stroke(for: ch) != nil, "\(ch)")
        }
        #expect(RealInput.stroke(for: "é") == nil)
        #expect(RealInput.stroke(for: "\"")?.flags.contains(.shift) == true)
    }
}
