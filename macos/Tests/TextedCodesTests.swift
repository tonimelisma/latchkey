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
        let first = await c.take(since: start)
        #expect(first?.code == "333333" && first?.message == "b")
        #expect(await c.take(since: start)?.message == "b", "not used until typed")
        c.markUsed("b")
        let second = await c.take(since: start)
        #expect(second?.code == "222222", "each text once")
        c.markUsed("a")
        #expect(await c.take(since: start) == nil, "the old one came before")
    }

    @Test func whileMessagesIsOffNoTextIsUsed() async {
        let texts = Texts()
        texts.all = [.init(id: "a", text: "222222 is your code", date: Date())]
        let c = codes(texts, on: false)
        #expect(await c.take(since: Date().addingTimeInterval(-10)) == nil)
        #expect(texts.asked.isEmpty, "Messages isn't even read")
    }

    /// FR-1360: texts since the last password typed on the site in the last 10 minutes, else the
    /// last 3 minutes.
    @Test func codesAreLookedForSinceTheLastPassword() {
        let c = codes(Texts())
        let t0 = Date()
        #expect(c.since("a.test", now: t0) == t0.addingTimeInterval(-180), "no password typed: the last 3 minutes")
        c.passwordTyped("a.test", at: t0.addingTimeInterval(-60))
        #expect(c.since("a.test", now: t0) == t0.addingTimeInterval(-60))
        #expect(
            c.since("a.test", now: t0.addingTimeInterval(700)) == t0.addingTimeInterval(520), "older than 10 minutes")
        #expect(c.since("b.test", now: t0) == t0.addingTimeInterval(-180), "per site")
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
