import Foundation
import Testing

@testable import Latchkey

/// Regression cases of sign-in (macos/scripts/state-check/cases.json), batch B. Real WebKit pages
/// given as text at an https address, as in SignInFillTests; the Mac's lock is a stand-in.
@MainActor @Suite struct RegressionLoginsBTests {
    struct Setup {
        let own: OwnPages
        let tool: ToolEntry
    }

    func setup(locked: Bool) throws -> Setup {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [SignInFillTests.ann], at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { locked }, record: { _ in })
        return Setup(own: own, tool: LoginsCapability.fill(store: s, own: own))
    }

    func call(_ s: Setup, _ page: String, _ args: [String: JSONValue]) async -> ToolResult {
        var a = args
        a["page"] = .string(page)
        return await s.tool.handler(.object(a))
    }

    /// regressions.browser_locked_bot_wall_guidance (Target, 2026-11-22) and
    /// regressions.logins_bot_protection_guidance: logins_fill's description says what to do when
    /// a site's protection against bots turns Latchkey's background browser away, both ways.
    @Test func theDescriptionSaysWhatToDoAboutBotProtectionLockedAndUnlocked() throws {
        let d = try setup(locked: false).tool.tool.description ?? ""
        #expect(d.contains("protection against bots turns away Latchkey's own background browser"), "\(d)")
        #expect(d.contains("while the Mac is unlocked, move the page into a background Safari tab"), "\(d)")
        #expect(d.contains("Safari tab with browser_look sign_in_again and sign in there"), "\(d)")
        #expect(d.contains("while it is locked, tell the owner the site needs the Mac unlocked"), "\(d)")
        #expect(d.contains("so judge from the page"), "Claude reads the page, the tool doesn't")
    }

    /// regressions.logins_out_of_time (Costco, 0.8.216): the old sign-in ran past the relay's 60 s
    /// and left the password in the page's field. A fill is one action: its own deadline is well
    /// under the relay's, it answers with the page as it is even while the page keeps changing
    /// after the press, and the password is gone from the field.
    @Test func aFillAnswersInTimeOnAPageThatKeepsChangingAndLeavesNoPassword() async throws {
        let deadline = try #require(try setup(locked: false).tool.tool.deadlineMS)
        #expect(deadline <= 30_000 && deadline < 60_000, "\(deadline)")
        let s = try setup(locked: false)
        defer { s.own.closeAll() }
        // After the press the page never settles: it writes a line every 100 ms.
        let html =
            SignInFillTests.onePage(expect: "something else")
                + """
                <div id="busy"></div><script>
                document.getElementById('f').addEventListener('submit', function () {
                  var n = 0, busy = document.getElementById('busy');
                  setInterval(function () { busy.textContent = 'Signing on ' + (++n); }, 100);
                });
                </script>
                """
        let p = try await s.own.open(html: html, base: SignInFillTests.base)
        let started = ContinuousClock.now
        let r = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        // Every wait after the press is bounded; GitHub's runner is slower than any Mac (43 s
        // there, 2026-11-24), so the bound here only catches a wait that never ends.
        #expect(ContinuousClock.now - started < .seconds(120), "\(ContinuousClock.now - started)")
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("then pressed e3"), "\(r.plainText)")
        #expect(try await s.own.page(p).run("document.querySelector('[name=pw]').value") == "")
        #expect(!r.plainText.contains(SignInFillTests.ann.password))
    }

    /// regressions.logins_locked_citi_slow (Citi while locked, 0.8.218): a page still signing in
    /// after the password was answered "refused the sign-in", counted against the saved password,
    /// and moved to Safari's cookies. Now, while locked, the answer is the page as it is, judged by
    /// nobody, and the page stays where it was.
    @Test func whileLockedASlowSignInIsAnsweredWithThePageAndNotJudged() async throws {
        let s = try setup(locked: true)
        defer { s.own.closeAll() }
        let html = """
            <title>Sign on</title>
            <form id="f"><label>User ID <input data-latchkey="e1" name="u" autocomplete="username"></label>
            <label>Password <input data-latchkey="e2" name="pw" type="password" autocomplete="current-password"></label>
            <button data-latchkey="e3" type="submit">Sign On</button></form><p id="msg"></p>
            <script>
            document.getElementById('f').addEventListener('submit', function (ev) {
              ev.preventDefault(); document.getElementById('msg').textContent = 'Please wait while we sign you on';
            });
            </script>
            """
        let p = try await s.own.open(html: html, base: SignInFillTests.base)
        let user = await call(s, p, ["field": .string("e1"), "fill": .string("user")])
        #expect(!user.isError, "\(user.plainText)")
        let pw = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(!pw.isError, "\(pw.plainText)")
        #expect(pw.plainText.contains("Please wait while we sign you on"), "the page as it is: \(pw.plainText)")
        for said in [user.plainText, pw.plainText] {
            #expect(!said.contains("refused") && !said.contains("Signed in"), "nobody judges the page: \(said)")
        }
        #expect(s.own.safariPage(p) == nil, "still in Latchkey's own browser")
        // Nothing is counted against the saved password: the next fill types it again.
        let again = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(!again.isError, "\(again.plainText)")
    }
}
