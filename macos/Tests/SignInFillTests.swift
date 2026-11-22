import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1371 to FR-1374 (Toni, 2026-11-22: "Fill-only tool"): Latchkey types a saved user
/// name, password, or code into the field Claude names, presses the button Claude names, empties
/// what it typed, and answers with the page as it is. Claude judges the page. Real WebKit pages,
/// given as text at an https address; fields carry fixed references (`data-latchkey`), as the
/// page reading would give them.
@MainActor @Suite struct SignInFillTests {
    static let base = URL(string: "https://a.test/login")!
    static let ann = SavedSignIn(title: "A", site: "a.test", user: "ann", password: "pw-a\"'<x>", otp: nil)
    static let otp = "otpauth://totp/A:ann?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    /// A sign-in form: e1 user name, e2 password, e3 Sign in (shows "Welcome ann" only for the
    /// right password), e4 a button that does nothing, e5 a search box.
    static func onePage(expect password: String = ann.password) -> String {
        """
        <title>Sign in</title>
        <form id="f"><label>User name <input data-latchkey="e1" name="email" type="text" autocomplete="username"></label>
        <label>Password <input data-latchkey="e2" name="pw" type="password" autocomplete="current-password"></label>
        <button data-latchkey="e3" type="submit">Sign in</button></form>
        <button data-latchkey="e4" type="button">Help</button><input data-latchkey="e5" type="search">
        <p id="msg"></p>
        <script>
        document.getElementById('f').addEventListener('submit', function (ev) {
          ev.preventDefault();
          var u = document.querySelector('[name=email]').value, p = document.querySelector('[name=pw]').value;
          window.seen = (window.seen || 0) + 1;
          if (u === 'ann' && p === \(PageScripts.literal(password))) { document.body.innerHTML = '<h1>Welcome ann</h1>'; }
          else { document.getElementById('msg').textContent = 'Wrong password'; }
        });
        </script>
        """
    }

    /// Citi's code step as it is (2026-11-21): six one-character password boxes, then Continue (e9).
    static let codeBoxes = """
        <title>Verify</title><h2>Enter the one-time code</h2>
        <input data-latchkey="e3" class="pin" type="password" maxlength="1" inputmode="numeric">
        <input data-latchkey="e4" class="pin" type="password" maxlength="1" inputmode="numeric">
        <input data-latchkey="e5" class="pin" type="password" maxlength="1" inputmode="numeric">
        <input data-latchkey="e6" class="pin" type="password" maxlength="1" inputmode="numeric">
        <input data-latchkey="e7" class="pin" type="password" maxlength="1" inputmode="numeric">
        <input data-latchkey="e8" class="pin" type="password" maxlength="1" inputmode="numeric">
        <button data-latchkey="e9" id="c">Continue</button>
        <script>
        document.getElementById('c').onclick = function () {
          var v = Array.prototype.map.call(document.querySelectorAll('.pin'), function (b) { return b.value; }).join('');
          if (v === '320518') document.body.innerHTML = '<h1>Welcome ann</h1>';
        };
        </script>
        """

    /// A code field (e1) and Verify (e2): "Welcome ann" for 320518.
    static let codeField = """
        <title>Verify</title><label>Code <input data-latchkey="e1" autocomplete="one-time-code"></label>
        <button data-latchkey="e2" id="v">Verify</button>
        <script>
        document.getElementById('v').onclick = function () {
          var v = document.querySelector('[data-latchkey=e1]').value;
          document.body.innerHTML = v === '320518' ? '<h1>Welcome ann</h1>' : '<p>Code was ' + v.length + ' long</p>';
        };
        </script>
        """

    struct Setup {
        let own: OwnPages
        let tool: ToolEntry
        let store: SignInStore
    }

    func setup(_ logins: [SavedSignIn] = [ann], locked: Bool = false) throws -> Setup {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: logins, at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { locked }, record: { _ in })
        return Setup(own: own, tool: LoginsCapability.fill(store: s, own: own), store: s)
    }

    func call(_ s: Setup, _ page: String, _ args: [String: JSONValue]) async -> ToolResult {
        var a = args
        a["page"] = .string(page)
        return await s.tool.handler(.object(a))
    }

    func run(_ s: Setup, _ page: String, _ js: String) async throws -> String {
        try await s.own.page(page).run(js)
    }

    // MARK: user name and password

    @Test func typesTheUserNameThenThePasswordAndPressesTheButtonClaudeNamed() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.onePage(), base: Self.base)
        let user = await call(s, p, ["field": .string("e1"), "fill": .string("user")])
        #expect(!user.isError, "\(user.plainText)")
        #expect(user.plainText.contains("Typed the saved user name for a.test (ann) into e1."), "\(user.plainText)")
        #expect(try await run(s, p, "String(window.seen || 0)") == "0", "a user name alone presses nothing")
        let pw = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(!pw.isError, "\(pw.plainText)")
        #expect(pw.plainText.contains("Typed the saved password for a.test (ann) into e2, then pressed e3."))
        #expect(pw.plainText.contains("Welcome ann"), "the page as it is after the press")
        #expect(!pw.plainText.contains(Self.ann.password))
        #expect(!pw.plainText.contains("Signed in"), "Latchkey never judges the page")
        #expect(pw.activity == "Typed the saved password for a.test (ann), then pressed e3")
    }

    /// FR-1311: the password never stays in the page for a script to read, also when the site keeps
    /// its form after the press.
    @Test func thePasswordIsEmptiedAfterThePress() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.onePage(), base: Self.base)
        let r = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e4")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(try await run(s, p, "document.querySelector('[name=pw]').value") == "")
    }

    @Test func aPasswordGoesOnlyIntoAPasswordFieldAndOnlyWithAButton() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.onePage(), base: Self.base)
        let wrong = await call(s, p, ["field": .string("e5"), "fill": .string("password"), "press": .string("e3")])
        #expect(wrong.isError && wrong.plainText.contains("e5 isn't a password field"), "\(wrong.plainText)")
        #expect(try await run(s, p, "document.querySelector('[data-latchkey=e5]').value") == "")
        let noButton = await call(s, p, ["field": .string("e2"), "fill": .string("password")])
        #expect(noButton.isError && noButton.plainText.contains("press"), "\(noButton.plainText)")
        let user = await call(s, p, ["field": .string("e2"), "fill": .string("user")])
        #expect(user.isError && user.plainText.contains("e2 is a password field"), "\(user.plainText)")
        #expect(try await run(s, p, "String(window.seen || 0)") == "0", "nothing pressed")
        let missing = await call(s, p, ["field": .string("e77"), "fill": .string("user")])
        #expect(missing.isError && missing.plainText.contains("e77"))
    }

    /// A page that changes what is typed (an input mask that keeps nothing): said so, nothing pressed.
    @Test func aFieldThatDoesntHoldWhatWasTypedPressesNothing() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let html =
            Self.onePage()
            + "<script>document.querySelector('[name=pw]').addEventListener('input', function (e) { e.target.value = ''; });</script>"
        let p = try await s.own.open(html: html, base: Self.base)
        let r = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(r.isError && r.plainText.contains("didn't hold"), "\(r.plainText)")
        #expect(try await run(s, p, "String(window.seen || 0)") == "0")
    }

    @Test func noSignInForTheSiteSeveralUserNamesAndHttpsOnly() async throws {
        let s = try setup([Self.ann, SavedSignIn(title: "A2", site: "a.test", user: "bob", password: "b", otp: nil)])
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.onePage(), base: Self.base)
        let several = await call(s, p, ["field": .string("e1"), "fill": .string("user")])
        #expect(several.isError && several.plainText.contains("ann, bob"), "\(several.plainText)")
        let bob = await call(s, p, ["field": .string("e1"), "fill": .string("user"), "user": .string("bob")])
        #expect(!bob.isError && bob.plainText.contains("(bob)"))
        let other = try await s.own.open(html: Self.onePage(), base: URL(string: "https://b.test/login")!)
        let none = await call(s, other, ["field": .string("e1"), "fill": .string("user")])
        #expect(none.isError && none.plainText.contains("no saved sign-in for b.test"), "\(none.plainText)")
        let plain = try await s.own.open(html: Self.onePage(), base: URL(string: "http://a.test/")!)
        let http = await call(s, plain, ["field": .string("e1"), "fill": .string("user")])
        #expect(http.isError && http.plainText.contains("only on https"))
    }

    /// FR-1328: a page's own scripts can't make it another site.
    @Test func aPageCantClaimAnotherSitesAddress() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let html = Self.onePage() + "<script>history.replaceState(null, '', '/elsewhere');</script>"
        let p = try await s.own.open(html: html, base: URL(string: "https://a.test.evil.example/login")!)
        let r = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(r.isError, "\(r.plainText)")
        #expect(try await run(s, p, "document.querySelector('[name=pw]').value") == "")
    }

    /// FR-1373: Claude is told to judge the page itself, and what to do about bot protection.
    @Test func theDescriptionGuidesClaude() throws {
        let s = try setup()
        let d = s.tool.tool.description ?? ""
        #expect(d.contains("read the page") && d.contains("protection against bots") && d.contains("sign_in_again"))
        #expect(d.contains("locked"))
        let on = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels)
        #expect(on.tools.contains { $0.name == "logins_fill" } && !on.tools.contains { $0.name == "logins_sign_in" })
    }

    // MARK: codes (Toni, 2026-11-22: "The agent reads the messages, archives them etc")

    @Test func aCodeClaudeReadGoesAcrossTheBoxesAndClaudeIsToldToCleanUp() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.codeBoxes, base: Self.base)
        let r = await call(
            s, p, ["field": .string("e3"), "fill": .string("code"), "press": .string("e9"), "code": .string("320518")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("Typed the code you passed into e3 (6 boxes), then pressed e9."), "\(r.plainText)")
        #expect(r.plainText.contains("Welcome ann") && r.plainText.contains("messages_delete"))
        let bad = await call(
            s, p, ["field": .string("e3"), "fill": .string("code"), "press": .string("e9"), "code": .string("32; x")])
        #expect(bad.isError && bad.plainText.contains("4 to 10 letters or digits"))
    }

    /// Without a code from Claude or Passwords, nothing is typed: Claude reads it itself.
    @Test func withoutACodeClaudeIsToldToReadIt() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.codeField, base: Self.base)
        let r = await call(s, p, ["field": .string("e1"), "fill": .string("code"), "press": .string("e2")])
        #expect(
            r.isError && r.plainText.contains("messages_read") && r.plainText.contains("mail_read"), "\(r.plainText)")
        #expect(try await run(s, p, "document.querySelector('[data-latchkey=e1]').value") == "")
    }

    /// Security review 2026-11-22: a code only into a code field, and never shown back by a page
    /// that prints what was typed (it matters for a code from Passwords, which Claude never sees).
    @Test func aCodeGoesOnlyIntoACodeFieldAndIsNeverShownBack() async throws {
        let s = try setup([SavedSignIn(title: "A", site: "a.test", user: "ann", password: "p", otp: Self.otp)])
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.onePage(), base: Self.base)
        let search = await call(s, p, ["field": .string("e5"), "fill": .string("code"), "press": .string("e4")])
        #expect(search.isError && search.plainText.contains("isn't a code field"), "\(search.plainText)")
        let name = await call(s, p, ["field": .string("e1"), "fill": .string("code"), "press": .string("e4")])
        #expect(name.isError && name.plainText.contains("not a code"), "\(name.plainText)")
        let echo = """
            <label>Verification code <input data-latchkey="e1" name="code"></label><button data-latchkey="e2" id="b">Go</button>
            <script>document.getElementById('b').onclick = function () { document.body.innerHTML = '<p>You typed ' + document.querySelector('[name=code]').value + '</p>'; };</script>
            """
        let q = try await s.own.open(html: echo, base: Self.base)
        let r = await call(s, q, ["field": .string("e1"), "fill": .string("code"), "press": .string("e2")])
        #expect(r.plainText.contains("You typed •••"), "\(r.plainText)")
        #expect(r.plainText.range(of: #"You typed \d"#, options: .regularExpression) == nil)
    }

    @Test func aCodeFromPasswordsIsTypedOncePerStep() async throws {
        let s = try setup([SavedSignIn(title: "A", site: "a.test", user: "ann", password: "p", otp: Self.otp)])
        defer { s.own.closeAll() }
        let p = try await s.own.open(html: Self.codeField, base: Self.base)
        let r = await call(s, p, ["field": .string("e1"), "fill": .string("code"), "press": .string("e2")])
        #expect(r.plainText.contains("Typed the code from Passwords into e1, then pressed e2."), "\(r.plainText)")
        #expect(r.plainText.contains("Code was 6 long"))
    }

    /// United's code boxes (2026-11-21): six fields with no one-character limit, alike in class and
    /// parent: the code goes one digit each from the first, as Claude named it.
    @Test func aRowOfAlikeFieldsTakesTheCodeOneDigitEach() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let html =
            "<div class=\"otp\">"
            + (1...6).map {
                "<input data-latchkey=\"e\($0)\" class=\"atm-c-otp-input\" aria-label=\"Enter digit \($0) of 6\">"
            }
            .joined()
            + "</div><button data-latchkey=\"e9\" id=\"go\">Continue</button>"
            + "<script>document.getElementById('go').onclick = function () { var v = Array.prototype.map.call(document.querySelectorAll('.atm-c-otp-input'), function (b) { return b.value; }).join(''); if (v === '320518') document.body.innerHTML = '<h1>Welcome ann</h1>'; };</script>"
        let p = try await s.own.open(html: html, base: Self.base)
        let r = await call(
            s, p, ["field": .string("e1"), "fill": .string("code"), "press": .string("e9"), "code": .string("320518")])
        #expect(r.plainText.contains("(6 boxes)") && r.plainText.contains("Welcome ann"), "\(r.plainText)")
    }

    // MARK: sign_in_again on a site Latchkey signs in to itself (FR-1374)

    @Test func whileLockedSigningInAgainOnAnOwnSiteSaysSafariWaitsForTheUnlock() async throws {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [Self.ann], at: Date(timeIntervalSince1970: 1_800_000_000))
        let sessions = OwnSessions(signIns: s, vault: MemoryVault())
        sessions.on = { true }
        let own = OwnPages(cookies: { [] }, isLocked: { true }, record: { _ in }, sessions: sessions)
        defer { own.closeAll() }
        let p = try await own.open(html: Self.onePage(), base: Self.base)
        let ops = BrowserCapability.readOperations(browser: SafariBrowser(scripts: FakeSafariTabs()), own: own)
        let again = try #require(ops.first { $0.tool.name == "browser_sign_in_again" })
        let r = await again.handler(.object(["page": .string(p)]))
        #expect(r.plainText.contains("once the Mac is unlocked"), "\(r.plainText)")
        #expect(r.plainText.contains("logins_fill") || !r.plainText.contains("logins_sign_in"))
    }
}
