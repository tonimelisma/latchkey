import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1311, FR-1321 to FR-1325: signing in on real WebKit pages, given as text at an
/// https address (no network). Each page plays a site's sign-in in script.
@MainActor @Suite struct SignInPageTests {
    static let base = URL(string: "https://a.test/login")!
    static let ann = SavedSignIn(title: "A", site: "a.test", user: "ann", password: "pw-a\"'<x>", otp: nil)
    static let otp = "otpauth://totp/A:ann?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    static let fixed = Date(timeIntervalSince1970: 1_800_000_010)

    func browser() -> LockedBrowser {
        let b = LockedBrowser(cookies: { [] })
        b.name = "ptest"
        return b
    }

    func run(_ b: LockedBrowser) -> SignInFlow.Run { { try await b.signInScript($0, navigates: $1) } }

    func signIn(_ b: LockedBrowser, _ login: SavedSignIn = ann, store: SignInStore? = nil) async throws
        -> (outcome: SignInFlow.Outcome, page: PageScripts.Page)
    {
        try await SignInFlow.signIn(
            login, exact: false, store: store ?? SignInStore(vault: MemoryVault()), run: run(b), now: { Self.fixed },
            wait: { _ in })
    }

    /// A site's page: `check(user, password)` decides; a right sign-in shows "Welcome".
    static func onePage(expect password: String = ann.password) -> String {
        """
        <title>Sign in</title>
        <form id="f"><label>User name <input name="email" type="text" autocomplete="username"></label>
        <label>Password <input name="pw" type="password" autocomplete="current-password"></label>
        <button type="submit">Sign in</button></form><p id="msg"></p>
        <script>
        document.getElementById('f').addEventListener('submit', function (ev) {
          ev.preventDefault();
          var u = document.querySelector('[name=email]').value, p = document.querySelector('[name=pw]').value;
          window.seen = (window.seen || 0) + 1;
          if (u === 'ann' && p === \(PageScripts.literal(password))) { document.body.innerHTML = '<h1>Welcome ann</h1>'; }
          else { document.getElementById('msg').setAttribute('role', 'alert'); document.getElementById('msg').textContent = 'Wrong password'; }
        });
        </script>
        """
    }

    @Test func signsInOnAOnePageFormAndShowsNoSecret() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: Self.onePage(), base: Self.base)
        let (outcome, page) = try await signIn(b)
        #expect(outcome == .signedIn)
        #expect(page.text.contains("Welcome ann"))
        #expect(!PageScripts.answer(page).contains(Self.ann.password))
    }

    @Test func aRefusedPasswordIsRefusedAndTheFieldIsCleared() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: Self.onePage(expect: "other"), base: Self.base)
        let (outcome, page) = try await signIn(b)
        #expect(outcome == .refused("Wrong password"))
        #expect(try await b.run("document.querySelector('[name=pw]').value") == "")
        #expect(try await b.run("String(window.seen)") == "1", "sent once, not again in the same call")
        #expect(!PageScripts.answer(page).contains(Self.ann.password))
    }

    @Test func aTwoPageSignInWithACode() async throws {
        let b = browser()
        defer { b.discard() }
        let code = try #require(TOTP(uri: Self.otp)).code(at: Self.fixed)
        let html = """
            <title>Sign in</title><div id="app">
            <input id="id" placeholder="Email or phone" type="text"><button id="next">Next</button></div>
            <script>
            var app = document.getElementById('app');
            document.getElementById('next').onclick = function () {
              if (document.getElementById('id').value !== 'ann') return;
              app.innerHTML = '<input id="pw" type="password"><button id="go">Sign in</button>';
              document.getElementById('go').onclick = function () {
                if (document.getElementById('pw').value !== \(PageScripts.literal(Self.ann.password))) return;
                app.innerHTML = '<label>Verification code <input id="otp" autocomplete="one-time-code" inputmode="numeric"></label><button id="v">Verify</button>';
                document.getElementById('v').onclick = function () {
                  app.innerHTML = document.getElementById('otp').value === \(PageScripts.literal(code)) ? '<h1>Welcome ann</h1>' : '<p role="alert">Wrong code</p>';
                };
              };
            };
            </script>
            """
        _ = try await b.open(html: html, base: Self.base)
        var login = Self.ann
        login.otp = Self.otp
        let (outcome, page) = try await signIn(b, login)
        #expect(outcome == .signedIn)
        #expect(page.text.contains("Welcome ann"))
    }

    @Test func aCodeItDoesntHoldIsSaidSo() async throws {
        let b = browser()
        defer { b.discard() }
        let html = """
            <form onsubmit="event.preventDefault(); document.body.innerHTML = '<label>Enter the code we texted you <input name=code autocomplete=one-time-code></label>';">
            <input name="username" autocomplete="username"><input type="password" name="p"><button>Log in</button></form>
            """
        _ = try await b.open(html: html, base: Self.base)
        #expect(try await signIn(b).outcome == .needsCode)
    }

    @Test func aFormInAFrameIsNeverFilled() async throws {
        let b = browser()
        defer { b.discard() }
        let html = """
            <p>Shop</p><iframe srcdoc="<form><input name=u><input type=password name=p><button>Sign in</button></form>"></iframe>
            """
        _ = try await b.open(html: html, base: Self.base)
        #expect(try await signIn(b).outcome == .noForm)
        #expect(
            try await b.run("document.querySelector('iframe').contentDocument.querySelector('[name=p]').value") == "")
    }

    @Test func anotherSitesPageGetsNothing() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: Self.onePage(), base: URL(string: "https://a.test.evil.example/login")!)
        #expect(try await signIn(b).outcome == .wrongSite)
        #expect(try await b.run("document.querySelector('[name=pw]').value") == "")
    }

    @Test func anExactSiteSkipsItsSubdomains() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: Self.onePage(), base: URL(string: "https://sub.a.test/login")!)
        let r = try await SignInFlow.signIn(
            Self.ann, exact: true, store: SignInStore(vault: MemoryVault()), run: run(b), now: { Self.fixed },
            wait: { _ in })
        #expect(r.outcome == .wrongSite)
    }

    @Test func aCaptchaIsSaidSo() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<p>Are you human?</p><div class=\"g-recaptcha\">x</div>", base: Self.base)
        #expect(try await signIn(b).outcome == .check)
    }
}
