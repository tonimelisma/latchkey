import Foundation
import Testing

@testable import Latchkey

/// Spec 008 FR-841 to FR-845 (plan D6a): email written by Mail's scripting, its text carried in
/// by a signature that exists for a moment, so it is sent while the Mac is locked and arrives
/// unquoted. A stand-in for Mail's scripting: nothing is ever made, shown, or sent.
@Suite struct MailSignatureWriteTests {
    /// Plays Mail: the accounts, the made message (its recipients before and after Latchkey's),
    /// and send, save, or close.
    final class FakeMail: @unchecked Sendable {
        let scripts = FakeScripts()
        /// What Mail's Reply fills in on its own.
        var mailsOwn: [String] = []
        /// Plays someone or something adding a recipient.
        var stray: String?
        var onSend: (@Sendable () -> Void)?
        var sendFails: ScriptError?

        init() {
            scripts.answer = { [unowned self] script, args in
                if script == MailScript.accounts { return MailTestEnv.accountsAnswer }
                if script == MailSignatureWriter.finishScript {
                    if args.last == "send" {
                        if let e = self.sendFails { throw e }
                        self.onSend?()
                    }
                    return "ok"
                }
                guard script == MailSignatureWriter.makeScript else { return "" }
                let kind = args[0]
                var out = self.mailsOwn.map { "before to \($0)" }
                out.append("id 7")
                let subject =
                    kind == "new"
                    ? args[4] : kind == "forward" ? "Fwd: Photos and lease" : "Re: Lease renewal"
                out.append("subject \(subject)")
                out.append("from Owner Person <\(args[5].isEmpty ? "owner@work.example" : args[5])>")
                out += self.mailsOwn.map { "to \($0)" }
                for i in stride(from: 8, to: args.count - 1, by: 2) where args[i] != "file" {
                    out.append("\(args[i]) \(args[i + 1])")
                }
                if let s = self.stray { out.append("to \(s)") }
                return out.joined(separator: "\n")
            }
        }

        func calls(_ script: String) -> [[String]] { scripts.calls.filter { $0.script == script }.map(\.args) }
    }

    static func run(
        _ tool: String, _ f: MailFixture, _ mail: FakeMail, _ w: FakeWindows = FakeWindows(),
        _ args: [String: JSONValue], confirm: Duration = .seconds(2)
    ) async throws -> ToolResult {
        try await MailTestEnv.tool(
            tool, MailTestEnv.make(f, scripts: mail.scripts, confirmWait: confirm, windows: w, byScript: true)
        )
        .handler(.object(args))
    }

    static func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "note-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func aNewMessageIsWrittenByScriptWithItsTextInASignature() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        mail.onSend = { f.recordSent(id: 5000, box: .sent, subject: "Lunch", to: "sam@example.com") }
        let w = FakeWindows()
        let r = try await Self.run(
            "mail_send", f, mail, w,
            [
                "to": .array([.string("sam@example.com")]), "cc": .array([.string("cc@example.com")]),
                "subject": .string("Lunch"), "text": .string("Noon?\nAt the usual place."), "from": .string("Work"),
            ])
        let text = MailTestEnv.text(r)
        #expect(!r.isError, "\(text)")
        #expect(w.opened.isEmpty, "no window")
        let made = try #require(mail.calls(MailSignatureWriter.makeScript).first)
        #expect(made[0..<6] == ["new", "", "", "", "Lunch", "owner@work.example"])
        #expect(!made[6].isEmpty, "a fresh signature name")
        #expect(made[7] == "Noon?\nAt the usual place.")
        #expect(Array(made[8...]) == ["to", "sam@example.com", "cc", "cc@example.com"])
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "send"]])
        #expect(
            text.contains("Sent to sam@example.com, cc@example.com from owner@work.example: «Lunch». It is in Sent"))
        #expect(r.activity == "Claude sent an email to sam@example.com: «Lunch»")
    }

    @Test func aReplyIsMadeOnTheExactMessageByScript() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        mail.mailsOwn = ["landlord@example.com"]
        mail.onSend = { f.recordSent(id: 5001, box: .sent, subject: "Re: Lease renewal", to: "landlord@example.com") }
        let w = FakeWindows()
        let r = try await Self.run(
            "mail_send", f, mail, w, ["reply_to": .string("1001"), "text": .string("Thanks, that works.")])
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.opened.isEmpty)
        let made = try #require(mail.calls(MailSignatureWriter.makeScript).first)
        #expect(made[0..<4] == ["reply", MailFixture.exchange, "Inbox", "1001"])
        #expect(made[5] == "owner@work.example", "from the address it came to")
        #expect(made.count == 8, "no recipients added")
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "send"]])
        #expect(
            MailTestEnv.text(r).contains("Sent to landlord@example.com from owner@work.example: «Re: Lease renewal»"))
    }

    /// The forward of 2026-11-04 (docs/use-cases.md) failed because Mail showed the Owner's name
    /// in place of the address; scripting reads addresses.
    @Test func aForwardToTheOwnersOwnAddressIsSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        let r = try await Self.run(
            "mail_send", f, mail, FakeWindows(),
            ["forward": .string("1003"), "to": .array([.string("owner@work.example")]), "text": .string("FYI")],
            confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        let made = try #require(mail.calls(MailSignatureWriter.makeScript).first)
        #expect(made[0] == "forward" && Array(made[8...]) == ["to", "owner@work.example"])
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "send"]])
    }

    @Test func aReplyMailAddressedElsewhereIsClosedUnsent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        mail.mailsOwn = ["eve@evil.example"]
        let r = try await Self.run(
            "mail_send", f, mail, FakeWindows(), ["reply_to": .string("1001"), "text": .string("Yes")])
        #expect(r.isError && MailTestEnv.text(r).hasPrefix("Nothing was sent"), "\(MailTestEnv.text(r))")
        #expect(MailTestEnv.text(r).contains("addressed to eve@evil.example"))
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "close"]])
    }

    @Test func aStrayRecipientIsNeverSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        mail.stray = "eve@evil.example"
        let r = try await Self.run(
            "mail_send", f, mail, FakeWindows(),
            ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")])
        #expect(r.isError && MailTestEnv.text(r).contains("To field has eve@evil.example, which wasn't asked for"))
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "close"]])
    }

    @Test func draftsAreSavedByScript() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        let r = try await Self.run(
            "mail_change", f, mail, FakeWindows(),
            ["action": .string("draft"), "to": .array([.string("sam@example.com")]), "subject": .string("Idea")])
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(mail.calls(MailSignatureWriter.finishScript) == [["7", "save"]])
        #expect(MailTestEnv.text(r).contains("Saved a draft to sam@example.com: «Idea»"))
    }

    @Test func worksWhileLockedAndWithoutAccessibility() async throws {
        for why in [AXMailWindows.whileLocked, AXMailWindows.needsAccessibility] {
            let f = try MailFixture()
            defer { f.close() }
            let mail = FakeMail()
            let w = FakeWindows()
            w.blocked = why
            let r = try await Self.run(
                "mail_send", f, mail, w,
                ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")],
                confirm: .zero)
            #expect(!r.isError, "\(MailTestEnv.text(r))")
            #expect(w.opened.isEmpty && mail.calls(MailSignatureWriter.finishScript) == [["7", "send"]])
        }
    }

    /// While locked a new message's files are attached by scripting (they come before the text).
    @Test func aLockedNewMessageWithFilesIsAttachedByScript() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let note = try Self.file()
        defer { try? FileManager.default.removeItem(at: note) }
        let mail = FakeMail()
        let w = FakeWindows()
        w.blocked = AXMailWindows.whileLocked
        let r = try await Self.run(
            "mail_send", f, mail, w,
            [
                "to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello"),
                "attachments": .array([.string(note.path)]),
            ], confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        let made = try #require(mail.calls(MailSignatureWriter.makeScript).first)
        #expect(Array(made[8...]) == ["to", "sam@example.com", "file", note.path])
        #expect(w.opened.isEmpty)
    }

    /// Attaching by scripting erases a reply's quoted original (tried 2026-11-05).
    @Test func aLockedReplyWithFilesIsRefusedAndTheQueueNamed() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let note = try Self.file()
        defer { try? FileManager.default.removeItem(at: note) }
        let mail = FakeMail()
        let w = FakeWindows()
        w.blocked = AXMailWindows.whileLocked
        let r = try await Self.run(
            "mail_send", f, mail, w,
            ["reply_to": .string("1001"), "text": .string("Here"), "attachments": .array([.string(note.path)])])
        let text = MailTestEnv.text(r)
        #expect(r.isError && text.hasPrefix("Nothing was sent") && text.contains("mail_queue"), "\(text)")
        #expect(mail.calls(MailSignatureWriter.makeScript).isEmpty && w.opened.isEmpty)
    }

    /// Unlocked, files still go through Mail's window, where they sit below the text.
    @Test func unlockedFilesStillUseTheWindow() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let note = try Self.file()
        defer { try? FileManager.default.removeItem(at: note) }
        let mail = FakeMail()
        let w = FakeWindows()
        _ = try await Self.run(
            "mail_send", f, mail, w,
            [
                "to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello"),
                "attachments": .array([.string(note.path)]),
            ], confirm: .zero)
        #expect(w.opened.count == 1 && mail.calls(MailSignatureWriter.makeScript).isEmpty)
    }

    @Test func aSendMailDidntAnswerIsNeverSaidUnsent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let mail = FakeMail()
        mail.sendFails = .timedOut
        let r = try await Self.run(
            "mail_send", f, mail, FakeWindows(),
            ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")])
        let text = MailTestEnv.text(r)
        #expect(
            r.isError && text.hasPrefix("Mail may not have sent it") && !text.contains("Nothing was sent"), "\(text)")
    }

    @Test func theSignatureNeverOutlivesTheScript() {
        let s = MailSignatureWriter.makeScript
        // Leftovers of a cut-off write are removed first; its own is removed on every path.
        #expect(s.contains("starts with sigPrefix then delete signature"))
        #expect(s.components(separatedBy: "delete signature sigName").count == 3)
        #expect(MailSignatureWriter.signaturePrefix == "Latchkey message ")
        #expect(s.contains("visible:false") && s.contains("opening window false"))
        #expect(!s.contains("set content"), "the text never goes in through content (it arrives quoted)")
    }

    @Test func parsesWhatMailMade() {
        let made = MailSignatureWriter.parse(
            "before to a@x.example\nid 12\nsubject Re: Hi there\nfrom Owner <o@x.example>\nto a@x.example\ncc b@x.example\nbcc c@x.example\n"
        )
        #expect(made.id == "12")
        #expect(made.before.to == ["a@x.example"] && made.before.subject == "Re: Hi there")
        #expect(
            made.after.to == ["a@x.example"] && made.after.cc == ["b@x.example"] && made.after.bcc == ["c@x.example"])
        #expect(made.after.from == "Owner <o@x.example>")
    }

    /// Mail's window showed the one address asked for twice (docs/use-cases.md, forward, 2026-11-04):
    /// a repeat of a token already paired with an asked address isn't a new recipient.
    @Test func aRecipientShownTwiceIsNotAnExtra() {
        let bob = KnownAddress(address: "bob@example.com", names: ["Bob Stone"])
        #expect(MailCompose.pair(["Bob Stone", "Bob Stone"], [bob]).extra.isEmpty)
        #expect(MailCompose.pair(["bob@example.com", "bob@example.com"], [bob]).extra.isEmpty)
        #expect(MailCompose.pair(["Bob Stone", "Eve"], [bob]).extra == ["Eve"])
        #expect(MailCompose.pair(["Eve", "Eve"], [bob]).extra == ["Eve", "Eve"])
    }
}
