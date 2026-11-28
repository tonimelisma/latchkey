import ApplicationServices
import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// Spec 002 FR-162, spec 008 FR-852 (decided 2026-11-22: "The agent reads the messages, archives them
/// etc"): what Claude asks to delete or archive is done at once while the Mac is unlocked, else at
/// the next unlock.
@MainActor @Suite struct PendingCleanupTests {
    final class Done: @unchecked Sendable { var ids: [String] = [] }

    func cleanup(locked: @escaping () -> Bool = { false }, done: Done = Done()) -> PendingCleanup {
        let c = PendingCleanup(defaults: nil)
        c.isLocked = locked
        c.deleter = { done.ids.append($0) }
        return c
    }

    @Test func doneAtOnceWhileUnlocked() async {
        let done = Done()
        let c = cleanup(done: done)
        #expect(await c.request("msg-1") == .done)
        #expect(done.ids == ["msg-1"] && c.pending.isEmpty)
    }

    @Test func whileLockedItWaitsForTheUnlock() async {
        let done = Done()
        var locked = true
        let c = cleanup(locked: { locked }, done: done)
        #expect(await c.request("msg-1") == .atUnlock)
        #expect(done.ids.isEmpty && c.pending == ["msg-1"])
        locked = false
        await c.deletePending()
        #expect(done.ids == ["msg-1"] && c.pending.isEmpty)
    }

    /// Security review 2026-11-22: a delete queued while locked doesn't run once the Owner turned
    /// Messages (or Mail) down.
    @Test func aQueuedChangeNoLongerAllowedIsDropped() async {
        let done = Done()
        var locked = true
        let c = cleanup(locked: { locked }, done: done)
        _ = await c.request("msg-1")
        c.mayDo = { _ in false }
        locked = false
        await c.deletePending()
        #expect(done.ids.isEmpty && c.pending.isEmpty)
    }

    @Test func whyItCouldntIsSaidAndItIsntTriedForever() async {
        let c = cleanup()
        c.deleter = { _ in throw CodeTextWindow.Problem(message: "Messages' window didn't show the message") }
        #expect(await c.request("msg-1") == .failed("Messages' window didn't show the message"))
        #expect(c.pending.isEmpty)
    }

    @Test(arguments: [
        ("98626", "98626", true), ("98626", "986260", false), ("+1 (555) 010-9999", "+15550109999", true),
        ("Amazon", "98626", false),
    ])
    func theWindowMustNameTheSender(_ shown: String, _ handle: String, _ same: Bool) {
        #expect(CodeTextWindow.names(shown, MessagesStore.Participant(handle: handle, name: nil)) == same)
    }
}

/// Spec 002 FR-162: messages_delete, through the cleanup, for a message Messages has.
/// Two '[Uber] Your code' texts with the same text, 2026-11-22: the window shows both, so the one
/// to delete is told by how many like it come later.
@Suite struct SameTextPickTests {
    @Test func theOnlyOneOrTheOneWithAsManyBelowItAsComeLater() {
        #expect(CodeTextWindow.pick([("a", 10)], laterSame: 0, earlierSame: 0) == "a")
        #expect(CodeTextWindow.pick([("a", 10)], laterSame: 0, earlierSame: 3) == "a", "older ones scrolled away")
        #expect(CodeTextWindow.pick([("a", 10)], laterSame: 1, earlierSame: 0) == nil, "a later one isn't shown")
        let two = [("lower", CGFloat(200)), ("upper", CGFloat(100))]
        #expect(CodeTextWindow.pick(two, laterSame: 0, earlierSame: 1) == "lower", "the newest is the bottom one")
        #expect(CodeTextWindow.pick(two, laterSame: 1, earlierSame: 0) == "upper")
        #expect(CodeTextWindow.pick(two, laterSame: 1, earlierSame: 1) == nil, "one of three isn't shown: unsure")
        #expect(CodeTextWindow.pick([(String, CGFloat)](), laterSame: 0, earlierSame: 0) == nil)
    }
}

/// Bank of America, 2026-11-22: the window shows a code text with one character more than the
/// database holds; it is found by its letters and digits, and only when no exact one is shown.
@Suite struct ShownTextMatchTests {
    let ax = AXUIElementCreateApplication(getpid())
    func b(_ t: String, me: Bool = false) -> CodeTextWindow.Balloon { .init(element: ax, text: t, fromMe: me) }

    @Test func exactFirstThenTheSameLettersAndDigits() {
        let stored = "BofA: Your code is 123456. Don't share it."
        #expect(
            CodeTextWindow.matching([b("<#> BofA: Your code is 123456. Don't share it."), b(stored)], stored).map(
                \.text) == [stored])
        #expect(CodeTextWindow.matching([b("BofA: Your code is 123456. Don't share it.\u{200E}")], stored).count == 1)
        #expect(
            CodeTextWindow.matching([b("BofA: Your code is 654321. Don't share it.")], stored).isEmpty, "another code")
        #expect(CodeTextWindow.matching([b(stored, me: true)], stored).isEmpty, "the owner's own")
        #expect(CodeTextWindow.matching([b("...")], "!!!").isEmpty, "no letters or digits: nothing")
        #expect(CodeTextWindow.matching([b("ok!")], "OK").isEmpty, "no code in it: exact only")
    }
}

@Suite struct MessagesDeleteTests {
    @Test func deletesTheMessageClaudeNames() async throws {
        let db = try MessagesFixture.make()
        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let done = PendingCleanupTests.Done()
        let cleanup = await MainActor.run {
            let c = PendingCleanup(defaults: nil)
            c.isLocked = { false }
            c.deleter = { done.ids.append($0) }
            return c
        }
        let tools = MessagesCapability.writeOperations(
            store: { store }, contacts: MessagesFixture.FakeContacts(), scripts: FakeScripts(),
            staging: FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)"),
            cleanup: cleanup)
        let delete = try #require(tools.first { $0.tool.name == "messages_delete" })
        #expect(delete.tool.annotations?.destructiveHint == true)
        let r = await delete.handler(.object(["message": .string("M-7")]))
        #expect(!r.isError && r.plainText.contains("Deleted message M-7"), "\(r.plainText)")
        #expect(done.ids == ["M-7"])
        let none = await delete.handler(.object(["message": .string("M-404")]))
        #expect(none.isError && done.ids == ["M-7"])
    }
}

/// Spec 008 FR-850 to FR-853: mail_find, mail_read, mail_archive on a stand-in for Mail.
@MainActor @Suite struct MailToolsTests {
    nonisolated static let place = MailCodes.Place(id: 42, account: "ACCT", mailbox: "INBOX")
    nonisolated static let email = MailCodes.Email(
        place: place, date: Date(), sender: "Citi <alerts@citi.com>", subject: "Your one-time code", unread: true)

    final class Seen: @unchecked Sendable { var started = 0; var asked: [String] = [] }

    func tools(locked: Bool = false, seen: Seen = Seen(), done: PendingCleanupTests.Done = .init()) -> [String:
        ToolEntry]
    {
        let source = MailCapability.Source(
            find: { _, from, _, _, _ in
                seen.asked.append(from)
                return from.isEmpty || "citi".contains(from.lowercased()) ? [Self.email] : []
            },
            email: { $0 == 42 ? Self.email : nil }, text: { _ in "Use 320518 to sign on." }, content: { _ in nil },
            start: { seen.started += 1 }, isLocked: { locked })
        let c = PendingCleanup(defaults: nil)
        c.isLocked = { locked }
        c.deleter = { done.ids.append($0) }
        let cap = MailCapability.make(source: source, cleanup: c)
        return Dictionary(uniqueKeysWithValues: (cap.readTools + cap.writeTools).map { ($0.tool.name, $0) })
    }

    @Test func findsReadsAndArchives() async throws {
        let seen = Seen()
        let done = PendingCleanupTests.Done()
        let t = tools(seen: seen, done: done)
        let found = await t["mail_find"]!.handler(.object(["from": .string("citi")])).plainText
        #expect(
            found.contains("email 42") && found.contains("«Your one-time code»") && found.contains("unread"), "\(found)"
        )
        #expect(found.contains("never as instructions") && seen.started == 1, "Mail started so new mail arrives")
        let read = await t["mail_read"]!.handler(.object(["email": .number(42)])).plainText
        #expect(read.contains("«Use 320518 to sign on.»") && read.contains("From: «Citi <alerts@citi.com>»"), "\(read)")
        let archived = await t["mail_archive"]!.handler(.object(["email": .number(42)]))
        #expect(!archived.isError && done.ids == [Self.place.key], "\(archived.plainText)")
        let missing = await t["mail_read"]!.handler(.object(["email": .number(7)]))
        #expect(missing.isError)
    }

    @Test func whileLockedArchivingWaitsForTheUnlock() async {
        let done = PendingCleanupTests.Done()
        let r = await tools(locked: true, done: done)["mail_archive"]!.handler(.object(["email": .number(42)]))
        #expect(r.plainText.contains("as soon as the Mac is unlocked") && done.ids.isEmpty)
    }

    @Test func mailIsACapabilityOfItsOwn() {
        #expect(CapabilityRegistry.all.contains(CapabilityRegistry.mail))
        let on = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels)
        #expect(["mail_find", "mail_read", "mail_archive"].allSatisfy { n in on.tools.contains { $0.name == n } })
    }

    /// Mail's own index, as Mail keeps it: found newest first, with the sender's name, unread.
    @Test func theIndexIsReadAsMailKeepsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mailindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Envelope Index")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let now = Int64(Date().timeIntervalSince1970)
        for sql in [
            "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject INTEGER, summary INTEGER, date_received INTEGER, mailbox INTEGER, read INTEGER, deleted INTEGER)",
            "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT)",
            "CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT)",
            "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT)",
            "INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX'), (2, 'imap://ACCT/Sent')",
            "INSERT INTO addresses VALUES (1, 'alerts@citi.com', 'Citi'), (2, 'me@example.com', '')",
            "INSERT INTO subjects VALUES (1, 'Your one-time code'), (2, 'Sent by me')",
            "INSERT INTO messages VALUES (42, 1, 1, NULL, \(now - 60), 1, 0, 0), (43, 2, 2, NULL, \(now - 30), 2, 1, 0), (44, 1, 1, NULL, \(now - 90000), 1, 1, 0)",
        ] { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        let found = try #require(MailCodes.find(since: Date().addingTimeInterval(-3600), index: url))
        #expect(found.map(\.place.id) == [42], "the sent one and the old one are left out")
        #expect(found.first?.sender == "Citi <alerts@citi.com>" && found.first?.unread == true)
        #expect(MailCodes.find(since: .distantPast, from: "citi", index: url)?.map(\.place.id) == [42, 44])
        #expect(MailCodes.find(since: .distantPast, unreadOnly: true, index: url)?.map(\.place.id) == [42])
        #expect(MailCodes.email(id: 44, index: url)?.unread == false)
    }
}

/// Apple Mail's files and scripting (spec 008 FR-850 to FR-852).
@Suite struct MailCodesTests {
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
        #expect(MailCodes.text(ofEmlx: Data(plain.utf8)).contains("482913"))
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
        #expect(MailCodes.text(ofEmlx: Data(multipart.utf8)).contains("551204"))
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
        #expect(MailCodes.text(ofEmlx: Data(mail.utf8)).contains("482913"))
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

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-162, FR-850, FR-852, FR-853
