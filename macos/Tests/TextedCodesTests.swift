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

    func run(_ texts: TextedCodesTests.Texts, deleted: TextedCodesTests.Deleted) async throws -> (
        ToolResult, TextedCodes, OwnPages
    ) {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: [SignInPageTests.ann], at: Date(timeIntervalSince1970: 1_800_000_000))
        let own = OwnPages(cookies: { [] }, isLocked: { false }, record: { _ in })
        let c = TextedCodesTests().codes(texts, deleted: deleted)
        c.perCall = .seconds(2)
        let name = try await own.open(html: Self.codePage, base: SignInToolsTests.base)
        let r = await LoginsCapability.signIn(store: s, own: own, move: { _ in nil }, codes: c).handler(
            .object(["page": .string(name)]))
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
        #expect(r.plainText.contains("Signed in to a.test as ann."), "\(r.plainText)")
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
        #expect(r.plainText.contains("hasn't reached Messages on this Mac yet"), "\(r.plainText)")
        #expect(!r.isError)
        let later = Date().addingTimeInterval(5)
        #expect(c.requested("a.test", now: later) < later, "the next call waits for the same text")
        #expect(deleted.ids.isEmpty)
        #expect(TextedCodes(defaults: nil).perCall < .seconds(60), "a real call fits in the relay's 60 s")
    }
}
