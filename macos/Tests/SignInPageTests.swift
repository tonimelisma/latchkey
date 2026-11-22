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

    /// Costco in a Safari tab, 2026-11-22: the call passed the relay's 60 s with the password still
    /// in the page. Once the time is nearly up no new step starts, and what was filled is cleared.
    @Test func noStepStartsOnceTheTimeIsUpAndTheFieldsAreCleared() async throws {
        let b = browser()
        defer { b.discard() }
        let twoSteps = """
            <title>Sign in</title><div id="app"><input name="email" type="text" autocomplete="username">
            <button id="next">Next</button></div>
            <script>
            document.getElementById('next').onclick = function () {
              document.getElementById('app').innerHTML = '<input name="email" type="text" autocomplete="username" value="ann"><input name="pw" type="password"><button id="go">Sign in</button>';
              document.getElementById('go').onclick = function () { window.sent = true; };
            };
            </script>
            """
        _ = try await b.open(html: twoSteps, base: Self.base)
        var calls = 0
        let r = try await SignInFlow.signIn(
            Self.ann, exact: false, store: SignInStore(vault: MemoryVault()), run: run(b), now: { Self.fixed },
            wait: { _ in },
            stillTime: {
                calls += 1
                return calls == 1
            })
        #expect(r.outcome == .outOfTime)
        #expect(try await b.run("String(window.sent === true)") == "false", "the password step never started")
        #expect(try await b.run("document.querySelector('[name=pw]').value") == "", "no password in the page")
    }

    /// A page that rewrites JavaScript's own functions can't pass for another site.
    @Test func aPageThatRewritesBuiltInsGetsNothing() async throws {
        let b = browser()
        defer { b.discard() }
        let poison = """
            <script>
            String.prototype.toLowerCase = function () { return 'a.test'; };
            String.prototype.slice = function () { return '.a.test'; };
            var real = JSON.stringify; JSON.stringify = function (v) { return real(Object.assign({}, v, { step: 'password' })); };
            </script>
            """
        _ = try await b.open(html: poison + Self.onePage(), base: URL(string: "https://evil.example/login")!)
        #expect(try await signIn(b).outcome == .wrongSite)
        #expect(try await b.run("document.querySelector('[name=pw]').value") == "")
    }

    @Test func aCaptchaIsSaidSo() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: "<p>Are you human?</p><div class=\"g-recaptcha\">x</div>", base: Self.base)
        #expect(try await signIn(b).outcome == .check)
    }

    /// Amazon, 2026-11-21: after the password, "Check the box to continue. I am human" (no captcha
    /// frame) was answered "Signed in".
    @Test func aHumanCheckWithoutACaptchaFrameIsACheck() async throws {
        let b = browser()
        defer { b.discard() }
        let page = Self.onePage().replacingOccurrences(
            of: "'<h1>Welcome ann</h1>'",
            with: PageScripts.literal(
                "<p>Hello, ann</p><h2>Check the box to continue.</h2><label><input type=\"checkbox\"> I am human</label>"
            ))
        _ = try await b.open(html: page, base: Self.base)
        #expect(try await signIn(b).outcome == .check)
    }

    /// Live check 2026-11-21 (homerecording.com): a forum's page after signing in carried Google
    /// ads, whose script adds a hidden reCAPTCHA frame; Latchkey answered "a check it can't
    /// answer" though Claude was signed in. Only a challenge the page shows counts.
    @Test func captchaPartsThePageDoesntShowArentACheck() async throws {
        let b = browser()
        defer { b.discard() }
        let after = """
            <h1>Welcome ann</h1>\
            <iframe src="about:blank#/recaptcha/api2/aframe" style="display:none"></iframe>\
            <iframe src="about:blank#/recaptcha/api2/aframe" width="0" height="0" style="border:0"></iframe>\
            <div class="grecaptcha-badge" style="width:256px;height:60px">\
            <iframe src="about:blank#/recaptcha/api2/anchor?size=invisible" width="256" height="60"></iframe></div>
            """
        let page = Self.onePage().replacingOccurrences(of: "'<h1>Welcome ann</h1>'", with: PageScripts.literal(after))
        #expect(page.contains("grecaptcha-badge"))
        _ = try await b.open(html: page, base: Self.base)
        #expect(try await signIn(b).outcome == .signedIn)
    }

    /// Citi, 2026-11-21: an input mask keeps only what comes with a real key press (a key code),
    /// and puts its own model back on every input; a value set in one go came out as "uu".
    static let masked = """
        <form id="f"><input id="Signon_username" type="text"><input id="p" type="password"><button>Sign on</button></form><p id="m"></p>
        <script>
        var model = '', u = document.getElementById('Signon_username');
        u.addEventListener('keydown', function (ev) { if (ev.keyCode > 0 && ev.key.length === 1) model += ev.key; });
        u.addEventListener('input', function () { u.value = model; });
        document.getElementById('f').addEventListener('submit', function (ev) {
          ev.preventDefault();
          var ok = u.value === 'ann' && document.getElementById('p').value === \(PageScripts.literal(ann.password));
          if (ok) { document.body.innerHTML = '<h1>Welcome ann</h1>'; }
          else { var m = document.getElementById('m'); m.className = 'cds-error'; m.textContent = 'Enter a valid user ID'; }
        });
        </script>
        """

    @Test func anInputMaskTakesWhatIsTypedKeyByKey() async throws {
        let b = browser()
        defer { b.discard() }
        _ = try await b.open(html: Self.masked, base: Self.base)
        let (outcome, page) = try await signIn(b)
        #expect(outcome == .signedIn, "\(page.text)")
    }

    /// A field that won't hold what is typed: nothing is sent, and it is no refusal.
    @Test func aFieldThatWontHoldTheValueSendsNothing() async throws {
        let b = browser()
        defer { b.discard() }
        let html = """
            <form id="f"><input id="u" autocomplete="username"><input id="p" type="password"><button>Sign in</button></form>
            <script>
            document.getElementById('u').addEventListener('input', function (ev) { ev.target.value = ''; });
            window.sent = 0;
            document.getElementById('f').addEventListener('submit', function (ev) { ev.preventDefault(); window.sent++; });
            </script>
            """
        _ = try await b.open(html: html, base: Self.base)
        let store = SignInStore(vault: MemoryVault())
        #expect(try await signIn(b, store: store).outcome == .couldntFill)
        #expect(try await b.run("String(window.sent)") == "0")
        #expect(!store.blocked(Self.ann) && store.refused(Self.ann) == 1, "nothing counted before")
    }

    /// Citi, 2026-11-21: its "Skip to Content" link is a live region; the site's error is what's said.
    @Test func theSitesErrorIsSaidNotASkipLink() async throws {
        let b = browser()
        defer { b.discard() }
        let page =
            "<a href=\"#main\" aria-live=\"assertive\">Skip to Content</a><span class=\"cds-error\" style=\"display:none\">Enter a valid password</span>"
            + Self.onePage(expect: "something else")
        _ = try await b.open(html: page, base: Self.base)
        let (outcome, _) = try await signIn(b)
        #expect(outcome == .refused("Wrong password"))
    }
}
