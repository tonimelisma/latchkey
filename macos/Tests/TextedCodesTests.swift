import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1360 to FR-1363: a code the site texts is taken from Messages, filled by Latchkey,
/// used once, and the text deleted after (at once while unlocked, else at the next unlock).
@MainActor @Suite struct TextedCodesTests {
    /// Messages' texts as the test sets them; read from another thread while the test writes.
    final class Texts: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [TextedCodes.Text] = []
        private var _asked: [Date] = []
        var all: [TextedCodes.Text] {
            get { lock.withLock { _all } }
            set { lock.withLock { _all = newValue } }
        }
        var asked: [Date] {
            get { lock.withLock { _asked } }
            set { lock.withLock { _asked = newValue } }
        }
    }

    final class Deleted: @unchecked Sendable { var ids: [String] = [] }

    func codes(_ texts: Texts, on: Bool = true, locked: Bool = false, deleted: Deleted = Deleted()) -> TextedCodes {
        let c = TextedCodes(defaults: nil)
        c.on = { on }
        c.recent = { since in
            texts.asked.append(since)
            return texts.all.filter { $0.date >= since }
        }
        c.isLocked = { locked }
        c.deleter = { deleted.ids.append($0) }
        return c
    }

    @Test(arguments: [
        ("320518 is your Amazon OTP. Do not share it with anyone.", "320518"),
        ("G-482913 is your Google verification code.", "482913"),
        ("Your code: 0042. Questions? Call 555 0199 2211.", "0042"),
        ("Order 77 shipped to 12 Main St. Your verification code is 918273", "918273"),
        ("Koodisi on 5521", "5521"),
    ])
    func findsTheCode(_ text: String, _ code: String) {
        #expect(TextedCodes.code(in: text) == code)
    }

    @Test(arguments: [
        "See you at 7", "Your package is on its way", "Pin 123", "Ref 1234567890", "Meet at 1830 by the door",
        "Call me at 5551 when you land",
    ])
    func noCodeWhereThereIsNone(_ text: String) {
        #expect(TextedCodes.code(in: text) == nil)
    }

    @Test func takesTheNewestNewCodeTextOnce() async {
        let texts = Texts()
        let start = Date()
        texts.all = [
            .init(id: "old", text: "111111 is your code", date: start.addingTimeInterval(-600)),
            .init(id: "a", text: "222222 is your code", date: start.addingTimeInterval(5)),
            .init(id: "b", text: "333333 is your code", date: start.addingTimeInterval(9)),
        ]
        let c = codes(texts)
        let first = await c.wait(since: start, until: .now + .seconds(1))
        #expect(first?.code == "333333" && first?.message == "b")
        let second = await c.wait(since: start, until: .now + .seconds(1))
        #expect(second?.code == "222222", "each text once")
        let none = await c.wait(since: start, until: .now + .milliseconds(200), poll: .milliseconds(50))
        #expect(none == nil, "the old one came before the sign-in began")
    }

    @Test func waitsForATextStillOnItsWay() async {
        let texts = Texts()
        let c = codes(texts)
        let start = Date()
        // Off the main thread, which the suite's WebKit tests keep busy.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            texts.all = [.init(id: "late", text: "Your Amazon OTP is 445566", date: Date())]
        }
        let got = await c.wait(since: start, until: .now + .seconds(20), poll: .milliseconds(50))
        #expect(got?.code == "445566")
    }

    @Test func whileMessagesIsOffNoTextIsUsed() async {
        let texts = Texts()
        texts.all = [.init(id: "a", text: "222222 is your code", date: Date())]
        let c = codes(texts, on: false)
        #expect(await c.wait(since: Date().addingTimeInterval(-10), until: .now + .seconds(1)) == nil)
        #expect(texts.asked.isEmpty, "Messages isn't even read")
    }

    @Test func aSitesRequestIsKeptForTwoMinutes() {
        let c = codes(Texts())
        let t0 = Date()
        #expect(c.requested("a.test", now: t0) == t0)
        #expect(c.requested("a.test", now: t0.addingTimeInterval(30)) == t0, "a second call waits for the same text")
        #expect(c.requested("a.test", now: t0.addingTimeInterval(130)) == t0.addingTimeInterval(130))
        c.forget("a.test")
        #expect(c.requested("a.test", now: t0.addingTimeInterval(140)) == t0.addingTimeInterval(140))
    }

    @Test func aUsedTextIsDeletedAtOnceWhileUnlocked() async {
        let deleted = Deleted()
        let c = codes(Texts(), deleted: deleted)
        await c.used("msg-1", site: "a.test")
        #expect(deleted.ids == ["msg-1"] && c.pending.isEmpty)
    }

    @Test func whileLockedItWaitsForTheUnlock() async {
        let deleted = Deleted()
        var locked = true
        let c = codes(Texts(), deleted: deleted)
        c.isLocked = { locked }
        await c.used("msg-1", site: "a.test")
        #expect(deleted.ids.isEmpty && c.pending == ["msg-1"])
        locked = false
        await c.deletePending()
        #expect(deleted.ids == ["msg-1"] && c.pending.isEmpty)
    }

    @Test func aTextThatCantBeDeletedIsntTriedForever() async {
        let c = codes(Texts())
        c.deleter = { _ in throw CodeTextWindow.Problem(message: "Messages' window didn't show the message") }
        await c.used("msg-1", site: "a.test")
        #expect(c.pending.isEmpty)
    }

    /// Security review 2026-11-21: deleting is a change in Messages, so only while it is Read & write.
    @Test func whileMessagesIsReadOnlyTheTextStays() async {
        let deleted = Deleted()
        let c = codes(Texts(), deleted: deleted)
        c.mayDelete = { false }
        await c.used("msg-1", site: "a.test")
        #expect(deleted.ids.isEmpty && c.pending.isEmpty)
    }

    @Test(arguments: [
        ("98626", "98626", true), ("98626", "986260", false), ("+1 (555) 010-9999", "+15550109999", true),
        ("Amazon", "98626", false),
    ])
    func theWindowMustNameTheSender(_ shown: String, _ handle: String, _ same: Bool) {
        #expect(CodeTextWindow.names(shown, MessagesStore.Participant(handle: handle, name: nil)) == same)
    }
}

/// The sign-in itself with a texted code (FR-1360, FR-1361), on the real WebKit view.
@MainActor @Suite struct TextedCodeSignInTests {
    static let codePage = """
        <title>Sign in</title><div id="app">
        <input id="u" autocomplete="username"><input id="pw" type="password"><button id="go">Sign in</button></div>
        <script>
        var app = document.getElementById('app');
        document.getElementById('go').onclick = function () {
          app.innerHTML = '<label>Enter the code we texted you <input id="otp" autocomplete="one-time-code"></label><button id="v">Verify</button><p id="m"></p>';
          document.getElementById('v').onclick = function () {
            // As sites do: a wrong code keeps the code field, with the error beside it.
            if (document.getElementById('otp').value === '320518') { app.innerHTML = '<h1>Welcome ann</h1>'; return; }
            var m = document.getElementById('m'); m.setAttribute('role', 'alert'); m.textContent = 'Wrong code';
          };
        };
        </script>
        """

    func run(
        _ texts: TextedCodesTests.Texts, deleted: TextedCodesTests.Deleted, args: [String: JSONValue] = [:],
        mail: TextedCodesTests.Texts = .init(), started: TextedCodesTests.Deleted = .init(),
        page html: String = TextedCodeSignInTests.codePage,
        content: @escaping (MailCodes.Place) async -> String? = { _ in nil }
    ) async throws -> (ToolResult, TextedCodes, OwnPages) {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [SignInPageTests.ann], at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        let c = TextedCodesTests().codes(texts, deleted: deleted)
        c.perCall = .seconds(2)
        c.firstWait = .seconds(2)
        c.recentMail = { since in
            mail.asked.append(since)
            return mail.all.filter { $0.date >= since }
        }
        c.startMail = { started.ids.append("mail") }
        c.mailContent = content
        let name = try await own.open(html: html, base: SignInToolsTests.base)
        var call = args
        call["page"] = .string(name)
        let r = await LoginsCapability.signIn(store: s, own: own, move: { _ in nil }, codes: c).handler(
            .object(call))
        return (r, c, own)
    }

    @Test func signsInWithTheTextedCodeAndDeletesTheText() async throws {
        let texts = TextedCodesTests.Texts()
        // Dated as if it arrives once the sign-in asked (opening the page may take seconds under load).
        texts.all = [
            .init(
                id: "otp-1", text: "320518 is your Amazon OTP. Do not share it with anyone.",
                date: Date().addingTimeInterval(60))
        ]
        let deleted = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(texts, deleted: deleted)
        defer { own.closeAll() }
        #expect(
            r.plainText.contains("Signed in to a.test as ann with a code the site texted to the owner"),
            "\(r.plainText)")
        #expect(!r.plainText.contains("320518"), "Claude never sees the code")
        #expect(deleted.ids == ["otp-1"])
    }

    /// Security review 2026-11-21: a text whose code the site refused may not have been a code
    /// text at all, so it stays.
    @Test func aTextWhoseCodeIsRefusedStays() async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [.init(id: "other", text: "Your code is 999999", date: Date().addingTimeInterval(60))]
        let deleted = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(texts, deleted: deleted)
        defer { own.closeAll() }
        #expect(r.plainText.contains("refused"), "\(r.plainText)")
        #expect(deleted.ids.isEmpty)
    }

    @Test func aTextStillOnItsWayAsksForAnotherCall() async throws {
        let texts = TextedCodesTests.Texts()
        let deleted = TextedCodesTests.Deleted()
        let (r, c, own) = try await run(texts, deleted: deleted)
        defer { own.closeAll() }
        // The page says the code was texted: no question about email (United, 2026-11-21).
        #expect(r.plainText.contains("texted a verification code"), "\(r.plainText)")
        #expect(!r.plainText.contains("Can you read the owner's email"))
        #expect(!r.isError)
        let later = Date().addingTimeInterval(5)
        #expect(c.requested("a.test", now: later) < later, "the next call waits for the same text")
        #expect(deleted.ids.isEmpty)
        #expect(TextedCodes(defaults: nil).perCall < .seconds(60), "a real call fits in the relay's 60 s")
    }

    // MARK: codes sent by email (FR-1364 to FR-1366)

    /// Toni, 2026-11-21: Claude's own email tool first; the code it found is filled in.
    @Test func aCodeClaudeReadInEmailIsFilledIn() async throws {
        let deleted = TextedCodesTests.Deleted()
        let started = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(
            .init(), deleted: deleted, args: ["code": .string("320518")], started: started)
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
        #expect(r.plainText.contains("archive it with your email tool"))
        #expect(deleted.ids.isEmpty && started.ids.isEmpty, "Apple Mail is never touched")
    }

    /// Toni, 2026-11-21: "script Mail for archiving anyway": the email with the code Claude found is
    /// archived through Apple Mail when Mail has it, without starting Mail.
    @Test func theEmailClaudeFoundIsArchivedInMailToo() async throws {
        let mail = TextedCodesTests.Texts()
        let key = MailCodes.Place(id: 9, account: "ACCT", mailbox: "Inbox").key
        mail.all = [.init(id: key, text: "From: noreply@a.test\nYour verification code is 320518", date: Date())]
        let deleted = TextedCodesTests.Deleted()
        let started = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(
            .init(), deleted: deleted, args: ["code": .string("320518")], mail: mail, started: started)
        defer { own.closeAll() }
        #expect(r.plainText.contains("archives it in Apple Mail"), "\(r.plainText)")
        #expect(deleted.ids == [key] && started.ids.isEmpty)
    }

    @Test func aCodeMustBeACode() async throws {
        let (r, _, own) = try await run(.init(), deleted: .init(), args: ["code": .string("320518; drop")])
        defer { own.closeAll() }
        #expect(r.isError && r.plainText.contains("4 to 10 letters or digits"))
    }

    /// Only when Claude says it has no email tool: Apple Mail is started and read, and the email
    /// marked read and archived after the sign-in worked.
    @Test func withoutAnEmailToolAppleMailIsRead() async throws {
        let mail = TextedCodesTests.Texts()
        let key = MailCodes.Place(id: 42, account: "ACCT", mailbox: "Inbox").key
        mail.all = [
            .init(
                id: key, text: "From: noreply@a.test\nYour verification code\nUse 320518 to sign in.",
                date: Date().addingTimeInterval(60))
        ]
        let deleted = TextedCodesTests.Deleted()
        let started = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(
            .init(), deleted: deleted, args: ["no_email_access": .bool(true)], mail: mail, started: started)
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
        #expect(started.ids == ["mail"] && deleted.ids == [key])
    }

    /// IKEA, 2026-11-21: Mail listed the email before downloading its body; the body is asked of
    /// Mail's scripting.
    @Test func aCodeRunningIntoTheNextSentenceIsFoundNotOneInsideAWord() {
        #expect(TextedCodes.code(in: "One-time code.482913Please do not share") == "482913")
        #expect(TextedCodes.code(in: "Your code: ab482913cd") == nil)
        #expect(TextedCodes.code(in: "Your code is 482913x") == nil)
    }

    @Test func aBodyNotYetDownloadedIsAskedOfMail() async throws {
        let mail = TextedCodesTests.Texts()
        let key = MailCodes.Place(id: 77, account: "ACCT", mailbox: "Inbox").key
        mail.all = [
            .init(
                id: key, text: "From: no.reply@a.test\nOne-time code to access your account.",
                date: Date().addingTimeInterval(60))
        ]
        let deleted = TextedCodesTests.Deleted()
        final class Asked: @unchecked Sendable { var n = 0 }
        let asked = Asked()
        let (r, _, own) = try await run(
            .init(), deleted: deleted, args: ["no_email_access": .bool(true)], mail: mail,
            content: { _ in
                asked.n += 1
                return "Enter the below code.320518Please do not share this."
            })
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
        #expect(asked.n >= 1 && deleted.ids == [key])
    }

    @Test func withoutNoEmailAccessAppleMailIsNeverRead() async throws {
        let mail = TextedCodesTests.Texts()
        mail.all = [.init(id: "mail:1\tA\tInbox", text: "code 320518", date: Date().addingTimeInterval(60))]
        let started = TextedCodesTests.Deleted()
        let (r, _, own) = try await run(.init(), deleted: .init(), mail: mail, started: started)
        defer { own.closeAll() }
        #expect(!r.plainText.contains("Signed in"), "\(r.plainText)")
        #expect(mail.asked.isEmpty && started.ids.isEmpty)
    }

    /// Citi, 2026-11-21: after the password, "We'll send a code to +1 ••• 0790" with Text me / Call
    /// me (its password field still showing): Text me is pressed, then the texted code is filled.
    static func citiLike(textMeEndsIt: Bool = false) -> String {
        let afterText =
            textMeEndsIt
            ? "app.innerHTML = '<input id=\"u\" autocomplete=\"username\"><input id=\"pw\" type=\"password\"><button>Sign on</button>';"
            : "app.innerHTML = '<label>Enter the code <input id=\"otp\" autocomplete=\"one-time-code\"></label><button id=\"v\">Verify</button>'; document.getElementById('v').onclick = function () { if (document.getElementById('otp').value === '320518') app.innerHTML = '<h1>Welcome ann</h1>'; };"
        return """
            <title>Sign on</title><div id="app">
            <input id="u" autocomplete="username"><input id="pw" type="password"><button id="go">Sign on</button></div>
            <script>
            var app = document.getElementById('app');
            document.getElementById('go').onclick = function () {
              app.innerHTML = '<p>Let us make sure it is you. We will send a code to +1 *** 0790.</p><input type="password" style="width:1px"><button id="t">Text me</button><button>Call me</button>';
              document.getElementById('t').onclick = function () { \(afterText) };
            };
            </script>
            """
    }

    @Test func aStepAskingHowToSendTheCodeIsAnswered() async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [
            .init(id: "otp-9", text: "Citi: your one-time code is 320518", date: Date().addingTimeInterval(60))
        ]
        let (r, _, own) = try await run(texts, deleted: .init(), page: Self.citiLike())
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
    }

    @Test func aSiteThatEndsTheSignInAtThatStepIsNoRefusal() async throws {
        let (r, _, own) = try await run(.init(), deleted: .init(), page: Self.citiLike(textMeEndsIt: true))
        defer { own.closeAll() }
        #expect(r.plainText.contains("shows a check Latchkey can't answer"), "\(r.plainText)")
        #expect(!r.plainText.contains("refused"))
    }

    /// United, 2026-11-21: a MileagePlus number shown masked after the first step, then six
    /// one-digit boxes whose input moves to the next box and whose delete in an empty box clears
    /// the box before (the first box came out empty).
    static let unitedLike = """
        <title>Sign in</title><div id="app">
        <input id="user" autocomplete="username"><button id="next">Continue</button></div>
        <script>
        var app = document.getElementById('app');
        document.getElementById('next').onclick = function () {
          if (document.getElementById('user').value.toLowerCase() !== 'ann') return;
          app.innerHTML = '<input id="user" autocomplete="username" value="******ann"><input id="pw" type="password"><button id="go">Sign in</button>';
          document.getElementById('go').onclick = function () {
            app.innerHTML = '<p>Enter the verification code sent via text.</p>' + [0,1,2,3,4,5].map(function (i) { return '<input class="b" maxlength="1" inputmode="numeric">'; }).join('') + '<button id="v">Continue</button>';
            var b = Array.prototype.slice.call(document.querySelectorAll('.b'));
            b.forEach(function (x, i) {
              x.addEventListener('input', function (ev) {
                if (ev.inputType === 'deleteContentBackward' && !x.value && i > 0) { b[i - 1].value = ''; b[i - 1].focus(); return; }
                if (x.value && i < 5) b[i + 1].focus();
              });
            });
            document.getElementById('v').onclick = function () {
              var c = b.map(function (x) { return x.value; }).join('');
              app.innerHTML = c === '320518' ? '<h1>Welcome ann</h1>' : '<p role="alert">Wrong code</p>';
            };
          };
        };
        </script>
        """

    @Test func sixCodeBoxesAreFilledWholeAfterAMaskedUserName() async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [
            .init(id: "ua-1", text: "Your United verification code is 320518.", date: Date().addingTimeInterval(60))
        ]
        let (r, _, own) = try await run(texts, deleted: .init(), page: Self.unitedLike)
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
    }

    /// United's second try (2026-11-21): a widget that knows its active box only from focus events
    /// (which a hidden browser doesn't fire on focus()) and redraws every box from its own state;
    /// a paste into the first box spreads the whole code.
    static func reactLike(pasteOnly: Bool = false) -> String {
        """
        <title>Sign in</title><div id="app"><input id="pw" type="password"><button id="go">Sign in</button></div>
        <script>
        var app = document.getElementById('app');
        document.getElementById('go').onclick = function () {
          app.innerHTML = '<p>Enter the code sent to ******0790 via text.</p><div id="w">' + [0,1,2,3,4,5].map(function () { return '<input class="b" maxlength="1" autocomplete="one-time-code">'; }).join('') + '</div><button id="v">Continue</button>';
          var b = Array.prototype.slice.call(document.querySelectorAll('.b')), vals = ['', '', '', '', '', ''], active = 0;
          function draw() { b.forEach(function (x, i) { x.value = vals[i]; }); }
          b.forEach(function (x, i) {
            x.addEventListener('focusin', function () { active = i; });
            x.addEventListener('paste', function (ev) {
              ev.preventDefault();
              var t = (ev.clipboardData && ev.clipboardData.getData('text/plain')) || '';
              t.split('').slice(0, 6).forEach(function (c, k) { vals[k] = c; }); draw();
            });
            x.addEventListener('input', function (ev) {
              if (\(pasteOnly ? "true" : "false")) { draw(); return; }
              var c = x.value.slice(-1); vals[active] = c; draw();
              if (c && active < 5) { active++; b[active].focus(); }
            });
          });
          document.getElementById('v').onclick = function () {
            app.innerHTML = vals.join('') === '320518' ? '<h1>Welcome ann</h1>' : '<p role="alert">Wrong code</p>';
          };
        };
        </script>
        """
    }

    @Test(arguments: [false, true])
    func codeBoxesThatFollowFocusEventsOrTakeOnlyAPaste(_ pasteOnly: Bool) async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [
            .init(id: "ua-2", text: "Your United verification code is 320518.", date: Date().addingTimeInterval(60))
        ]
        let (r, _, own) = try await run(texts, deleted: .init(), page: Self.reactLike(pasteOnly: pasteOnly))
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
    }

    /// United's real boxes (probed 2026-11-21): no length limit, no autocomplete, labelled
    /// "Enter code Enter digit N of 6", class atm-c-otp-input in div.atm-c-otp-input-item. Typed
    /// whole into the first box, each digit was pushed one box on and the first stayed empty.
    static let unitedReal = """
        <title>Sign in</title><div id="app"><input id="pw" type="password"><button id="go">Sign in</button></div>
        <script>
        var app = document.getElementById('app');
        document.getElementById('go').onclick = function () {
          app.innerHTML = '<p>Enter the verification code sent to ******0790 via text.</p>' + [1,2,3,4,5,6].map(function (n) { return '<div class="atm-c-otp-input-item"><input type="text" inputmode="numeric" autocomplete="off" class="atm-c-otp-input atm-c-otp-input--hover" aria-label="Enter code Enter digit ' + n + ' of 6"></div>'; }).join('') + '<input type="checkbox" name="rememberDevice"><button id="v">Continue</button>';
          var b = Array.prototype.slice.call(document.querySelectorAll('.atm-c-otp-input')), vals = ['', '', '', '', '', ''];
          function draw() { b.forEach(function (x, i) { x.value = vals[i]; }); }
          b.forEach(function (x, i) {
            x.addEventListener('input', function () {
              var t = x.value, c = t.slice(-1);
              if (t.length > 1 && i < 5) { vals[i] = ''; vals[i + 1] = c; draw(); b[i + 1].focus(); return; }
              vals[i] = c; draw();
              if (c && i < 5) b[i + 1].focus();
            });
          });
          document.getElementById('v').onclick = function () {
            app.innerHTML = vals.join('') === '320518' ? '<h1>Welcome ann</h1>' : '<p role="alert">Wrong code</p>';
          };
        };
        </script>
        """

    @Test func unitedsRealCodeBoxesAreFoundAndFilled() async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [
            .init(id: "ua-3", text: "Your United verification code is 320518.", date: Date().addingTimeInterval(60))
        ]
        let (r, _, own) = try await run(texts, deleted: .init(), page: Self.unitedReal)
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
    }

    /// GitHub, 2026-11-21: after the password a passkey page whose "SMS Code" link is hidden
    /// under "More options"; then "Send SMS" with the code field; the text came before Latchkey
    /// looked at the code page and was missed, and the passkey page was answered "Signed in".
    static let passkeyThenSms = """
        <title>Sign in</title><div id="app"><input id="login" autocomplete="username"><input id="pw" type="password"><button id="go">Sign in</button></div>
        <script>
        var app = document.getElementById('app'); window.sent = 0;
        document.getElementById('go').onclick = function () {
          app.innerHTML = '<h1>Two-factor authentication</h1><p>Use your passkey</p><button id="pk">Use passkey</button><details><summary>More options</summary><a href="#" id="sms">SMS Code</a></details>';
          document.getElementById('sms').onclick = function (ev) {
            ev.preventDefault();
            app.innerHTML = '<h1>Two-factor authentication</h1><button id="send">Send SMS</button><label>Authentication code <input id="otp" autocomplete="one-time-code"></label><button id="v">Verify</button>';
            document.getElementById('send').onclick = function () { window.sent++; };
            document.getElementById('v').onclick = function () {
              app.innerHTML = document.getElementById('otp').value === '320518' && window.sent === 1 ? '<h1>Welcome ann</h1>' : '<p role="alert">Wrong code</p>';
            };
          };
        };
        </script>
        """

    @Test func aPasskeyPageGoesToTheTextWayAndItsCodeIsUsed() async throws {
        let texts = TextedCodesTests.Texts()
        texts.all = [
            .init(id: "gh-1", text: "320518 is your GitHub authentication code.", date: Date().addingTimeInterval(60))
        ]
        let (r, _, own) = try await run(texts, deleted: .init(), page: Self.passkeyThenSms)
        defer { own.closeAll() }
        #expect(r.plainText.contains("Signed in to a.test as ann"), "\(r.plainText)")
    }

    @Test func aPasskeyOnlyPageIsACheckNotSignedIn() async throws {
        let page = Self.passkeyThenSms.replacingOccurrences(
            of: "<details><summary>More options</summary><a href=\"#\" id=\"sms\">SMS Code</a></details>", with: "")
        let (r, _, own) = try await run(.init(), deleted: .init(), page: page)
        defer { own.closeAll() }
        #expect(r.plainText.contains("passkey or security key"), "\(r.plainText)")
        #expect(!r.plainText.contains("Signed in"))
    }

    /// The code page may be reached a call after the text was sent: it still counts.
    @Test func aTextSentBeforeTheCodePageCounts() {
        let c = TextedCodesTests().codes(.init())
        let t0 = Date()
        c.noteCall("a.test", now: t0)
        #expect(c.requested("a.test", now: t0.addingTimeInterval(40)) == t0)
        #expect(c.mayDeliver("a.test", now: t0))
        c.delivered("a.test", now: t0)
        #expect(
            !c.mayDeliver("a.test", now: t0.addingTimeInterval(30))
                && c.mayDeliver("a.test", now: t0.addingTimeInterval(91)))
    }

    @Test func aCodeSentByTextIsSaidSoWithoutAskingAboutEmail() {
        #expect(TextedCodes.saysText("Enter the verification code sent to ******0790 via text."))
        #expect(!TextedCodes.saysText("We sent a code to your email or by text"))
        #expect(!TextedCodes.saysText("Enter the code we emailed you"))
    }

    /// A code a call took but couldn't finish with is tried once more by the next call.
    @Test func aCodeTakenEarlierIsTriedOnceMore() async {
        let texts = TextedCodesTests.Texts()
        let start = Date()
        texts.all = [.init(id: "t1", text: "Your code is 445566", date: start.addingTimeInterval(1))]
        let c = TextedCodesTests().codes(texts)
        #expect(await c.wait(since: start, until: .now + .seconds(1), site: "a.test")?.code == "445566")
        #expect(await c.wait(since: start, until: .now + .seconds(1), site: "a.test")?.code == "445566", "once more")
        #expect(
            await c.wait(since: start, until: .now + .milliseconds(200), poll: .milliseconds(50), site: "a.test") == nil
        )
    }
}

/// Apple Mail's side (FR-1365, FR-1366).
@Suite struct MailCodesTests {
    /// Security review 2026-11-21: an email code is used only from an email naming the site.
    @Test(arguments: [
        ("online.citi.com", "From: alerts@citibank.com\nYour one-time passcode", true),
        ("www.amazon.com", "From: account-update@amazon.com\nVerify", true),
        ("www.amazon.com", "From: deals@shop.example\nYour code 123456", false),
        ("a.test", "From: x@a.test", true), ("a.test", "From: x@b.test", false),
    ])
    func anEmailMustNameTheSite(_ site: String, _ text: String, _ names: Bool) {
        #expect(MailCodes.names(site, in: text) == names)
    }

    @Test func aPlaceComesFromMailsAddressAndBack() throws {
        let p = try #require(MailCodes.Place(id: 7, url: "ews://0FFA47A7-021E/Deleted%20Items"))
        #expect(p.account == "0FFA47A7-021E" && p.mailbox == "Deleted Items")
        #expect(MailCodes.Place(key: p.key) == p)
        #expect(MailCodes.Place(key: "sms-guid") == nil && MailCodes.Place(key: "mail:x\ty\tz") == nil)
        #expect(MailCodes.Place(id: 1, url: "imap://ACCT/INBOX")?.mailbox == "INBOX")
    }

    @Test(arguments: [
        ("Sent Items", true), ("Drafts", true), ("Deleted Items", true), ("INBOX", false), ("Junk", false),
    ])
    func whatTheOwnerSentNeverCounts(_ mailbox: String, _ skipped: Bool) {
        #expect(MailCodes.skipped(mailbox) == skipped)
    }

    /// Mail's preview text comes hours late (2026-11-21), so the code is read from the email's file.
    @Test func theCodeIsReadFromTheEmailItself() {
        let plain = "123\nSubject: x\nContent-Type: text/plain\n\nYour verification code is 482913.\n"
        #expect(TextedCodes.code(in: MailCodes.text(ofEmlx: Data(plain.utf8))) == "482913")
        let html = Data(
            "<html><head><style>.c{color:#000000}</style></head><body><p>Your code</p><strong>551204</strong></body></html>"
                .utf8
        ).base64EncodedString()
        let multipart = """
            900
            Subject: Sign in
            Content-Type: multipart/alternative; boundary="b1"

            --b1
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: base64

            \(html)
            --b1--
            """
        #expect(TextedCodes.code(in: MailCodes.text(ofEmlx: Data(multipart.utf8))) == "551204")
        let qp =
            "1\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\nYour one-time pass=\ncode: 7731=3D\n"
        #expect(MailCodes.text(ofEmlx: Data(qp.utf8)).contains("Your one-time passcode: 7731="))
    }

    /// IKEA, 2026-11-21: the byte count line is padded with spaces, and the plain text glues the
    /// code to the next word, while the HTML keeps it apart.
    @Test func ikeasCodeEmailIsRead() {
        let html =
            "<p>Enter the below six-digits in the view where you requested the IKEA One-time code.</p><table><tr><td>482913</td></tr></table><p>Please do not share</p>"
        let mail = """
            \("44036     ")
            From: no.reply@ikea.com
            Content-Type: multipart/alternative;
            \tboundary="----_NmP-0e22-Part_1"

            ------_NmP-0e22-Part_1
            Content-Type: text/plain; charset="utf-8"
            Content-Transfer-Encoding: quoted-printable

            HejEnter the below six-digits in the view where you requested the IKEA =
            One-time code.482913Please do not share this with anyone.
            ------_NmP-0e22-Part_1
            Content-Type: text/html; charset="utf-8"
            Content-Transfer-Encoding: quoted-printable

            \(html)
            ------_NmP-0e22-Part_1--
            """
        #expect(TextedCodes.code(in: MailCodes.text(ofEmlx: Data(mail.utf8))) == "482913")
    }

    @Test func theEmailsFileIsWhereMailKeepsIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mail-\(UUID().uuidString)")
        let dir = root.appending(path: "ACCT/Archive.mbox/STORE-1/Data/6/0/1/Messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("1\n\nx".utf8).write(to: dir.appending(path: "106222.emlx"))
        let found = MailCodes.file(of: .init(id: 106222, account: "ACCT", mailbox: "Archive"), in: root)
        #expect(found?.lastPathComponent == "106222.emlx")
        #expect(MailCodes.file(of: .init(id: 106223, account: "ACCT", mailbox: "Archive"), in: root) == nil)
    }

    final class Calls: ScriptRunner, @unchecked Sendable {
        var args: [[String]] = []
        var answer = "ok"
        func run(_ script: String, _ args: [String]) async throws -> String {
            self.args.append(args)
            return answer
        }
    }

    @Test func archivingNamesTheEmailByItsPlace() async throws {
        let calls = Calls()
        try await MailCodes.archive(.init(id: 42, account: "ACCT", mailbox: "Inbox"), runner: calls)
        #expect(calls.args == [["ACCT", "Inbox", "42"]])
        calls.answer = "not found"
        await #expect(throws: CodeTextWindow.Problem.self) {
            try await MailCodes.archive(.init(id: 42, account: "ACCT", mailbox: "Inbox"), runner: calls)
        }
    }
}
