import Foundation
import Testing

@testable import Latchkey

/// Regression cases of the group regressions-browser about signing in (spec 013), on real
/// WebKit pages of Claude's given as text: the part Latchkey's own code decides. The sites
/// themselves (Citi, Amazon, homerecording.com) are reproduced only in the structure that
/// mattered.
@MainActor @Suite struct RegressionLoginsCTests {
    static let base = URL(string: "https://a.test/login")!

    struct Setup {
        let own: OwnPages
        let tool: ToolEntry
    }

    func setup(_ logins: [SavedSignIn] = [SignInFillTests.ann]) throws -> Setup {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: logins, at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        return Setup(own: own, tool: LoginsCapability.fill(store: s, own: own))
    }

    func call(_ s: Setup, _ page: String, _ args: [String: JSONValue]) async -> ToolResult {
        var a = args
        a["page"] = .string(page)
        return await s.tool.handler(.object(a))
    }

    func run(_ s: Setup, _ page: String, _ js: String) async throws -> String {
        try await s.own.page(page).run(js)
    }

    /// regressions.logins_masked_field_and_real_error (Citi, 2026-11-21, 0.8.185): Citi's input
    /// mask cut a user ID set in one go to two letters; and two tries the page didn't take were
    /// counted as refusals that blocked the saved password. Now the user name is typed key by
    /// key, which the mask keeps, and nothing is counted: every fill types.
    @Test func aMaskThatKeepsOnlyKeyPressesHoldsTheUserNameAndNoTryIsCounted() async throws {
        let login = SavedSignIn(title: "Citi", site: "a.test", user: "tonimelisma", password: "pw-c", otp: nil)
        let s = try setup([login])
        defer { s.own.closeAll() }
        let mask = """
            <script>
            // Citi's mask: a value that didn't come one typed character at a time is cut to two.
            document.querySelector('[name=email]').addEventListener('input', function (ev) {
              if (!(ev.inputType === 'insertText' && ev.data && ev.data.length === 1)) ev.target.value = ev.target.value.slice(0, 2);
            });
            </script>
            <a href="#main">Skip to Content</a>
            """
        let p = try await s.own.open(html: SignInFillTests.onePage(expect: "not this one") + mask, base: Self.base)
        let user = await call(s, p, ["field": .string("e1"), "fill": .string("user")])
        #expect(!user.isError, "\(user.plainText)")
        #expect(user.plainText.contains("Typed the saved user name for a.test (tonimelisma) into e1."))
        #expect(try await run(s, p, "document.querySelector('[name=email]').value") == "tonimelisma")
        // The page turns the password away every time: each fill still types and presses.
        for _ in 0..<3 {
            let pw = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
            #expect(!pw.isError, "\(pw.plainText)")
            #expect(
                pw.plainText.contains("Typed the saved password for a.test (tonimelisma) into e2, then pressed e3."))
            #expect(pw.plainText.contains("Wrong password"), "the page as it is")
        }
        #expect(try await run(s, p, "String(window.seen || 0)") == "3", "pressed every time, never blocked")
    }

    /// regressions.logins_code_delivery_step (Citi, 2026-11-21, 0.8.187 and 0.8.205): the
    /// password went into Citi's first one-character code box (its six PIN boxes are password
    /// fields), and the tool pressed on by itself. A password goes only into a password field
    /// that isn't a one-character box, and nothing but the named button is pressed ("Text me" is
    /// Claude's to press).
    @Test func aPasswordNeverGoesIntoACodeBoxAndTextMeIsNeverPressed() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let boxes = try await s.own.open(html: SignInFillTests.codeBoxes, base: Self.base)
        let r = await call(s, boxes, ["field": .string("e3"), "fill": .string("password"), "press": .string("e9")])
        #expect(r.isError && r.plainText.contains("isn't a password field"), "\(r.plainText)")
        let typed = try await run(
            s, boxes,
            "Array.prototype.map.call(document.querySelectorAll('.pin'), function (b) { return b.value; })"
                + ".join('')")
        #expect(typed == "", "nothing typed into the boxes")
        let textMe = """
            <p>Let’s make sure it’s you. How should we send your code?</p>
            <button data-latchkey="e6" type="button" onclick="window.texted = (window.texted || 0) + 1">Text me</button>
            <button data-latchkey="e7" type="button" onclick="window.called = (window.called || 0) + 1">Call me</button>
            <p>Beware of scams: Citi will never ask for your PIN.</p>
            """
        let p = try await s.own.open(html: SignInFillTests.onePage() + textMe, base: Self.base)
        let pw = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(!pw.isError, "\(pw.plainText)")
        #expect(!pw.plainText.contains("Signed in"), "Latchkey never judges the page")
        let pressed = try await run(s, p, "String(window.texted || 0) + String(window.called || 0)")
        #expect(pressed == "00", "Text me and Call me are Claude's to press")
    }

    /// regressions.logins_hidden_ad_frame_not_a_check (homerecording.com, 2026-11-21, 0.8.177):
    /// the signed-in page carried a hidden frame from its ad script, and the answer said the
    /// site showed a check. The answer is the page as it is, never a judgment of it.
    @Test func aHiddenAdFrameIsNoCheckInTheAnswer() async throws {
        let s = try setup()
        defer { s.own.closeAll() }
        let ads = """
            <script>
            document.getElementById('f').addEventListener('submit', function () {
              document.body.insertAdjacentHTML('beforeend',
                '<div class="g-recaptcha" style="display:none"><iframe title="reCAPTCHA" src="about:blank" style="display:none"></iframe></div>');
            });
            </script>
            """
        let p = try await s.own.open(html: SignInFillTests.onePage() + ads, base: Self.base)
        let user = await call(s, p, ["field": .string("e1"), "fill": .string("user")])
        #expect(!user.isError, "\(user.plainText)")
        let r = await call(s, p, ["field": .string("e2"), "fill": .string("password"), "press": .string("e3")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("Welcome ann"), "the page as it is: \(r.plainText)")
        #expect(!r.plainText.contains("can't answer") && !r.plainText.contains("Signed in"), "\(r.plainText)")
        #expect(
            try await run(s, p, "String(document.querySelectorAll('iframe[title=reCAPTCHA]').length)") == "1",
            "the hidden frame is there")
    }
}
