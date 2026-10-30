import Foundation
import Testing

@testable import Latchkey

/// Spec 008 changes and sending (plan D6, D7), with a stand-in for Mail's scripting: nothing is
/// ever sent.
@Suite struct MailWriteTests {
    /// Answers the accounts script like Mail and the change script with "ok" for each id.
    static func scripts(compose: @escaping @Sendable ([String]) throws -> String = { _ in "sent" }) -> FakeScripts {
        let s = FakeScripts()
        s.answer = { script, args in
            if script == MailScript.accounts { return MailTestEnv.accountsAnswer }
            if script == MailScript.change {
                return stride(from: 4, to: args.count, by: 3).map { "ok \(args[$0])" }.joined(separator: "\n")
            }
            if script == MailScript.compose { return try compose(args) }
            return ""
        }
        return s
    }

    static func lastCall(_ s: FakeScripts, _ script: String) -> [String]? {
        s.calls.last { $0.script == script }?.args
    }

    @Test func organisesSeveralAtOnce() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let change = try MailTestEnv.tool("mail_change", MailTestEnv.make(f, scripts: s))
        let r = await change.handler(
            .object([
                "action": .string("mark_read"), "ids": .array([.string("1001"), .string("1004"), .string("4242")]),
            ]))
        let text = MailTestEnv.text(r)
        #expect(!r.isError, "\(text)")
        #expect(
            Self.lastCall(s, MailScript.change)
                == ["mark_read", "", MailFixture.exchange, "Inbox", "1001", MailFixture.gmail, "INBOX", "1004"])
        #expect(text.contains("Marked read: «Lease renewal» (id 1001), «Plan» (id 1004)."))
        #expect(text.contains("no message with id 4242"))
        #expect(r.activity == "Claude marked 2 emails read")
        for action in ["mark_unread", "flag", "unflag", "junk", "not_junk"] {
            let one = await change.handler(.object(["action": .string(action), "id": .string("1002")]))
            #expect(!one.isError && one.activity != nil, "\(action)")
            #expect(Self.lastCall(s, MailScript.change)?.first == action)
        }
    }

    @Test func deleteMovesToTrash() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let change = try MailTestEnv.tool("mail_change", MailTestEnv.make(f, scripts: s))
        let r = await change.handler(.object(["action": .string("delete"), "id": .string("1001")]))
        #expect(Self.lastCall(s, MailScript.change) == ["delete", "", MailFixture.exchange, "Inbox", "1001"])
        #expect(MailTestEnv.text(r).contains("Moved to its account's Trash"))
        #expect(r.activity == "Claude moved «Lease renewal» to Trash")
        #expect(MailScript.change.contains("trash mailbox") && !MailScript.change.contains("delete theMsg"))
    }

    @Test func movesWithinTheAccount() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let change = try MailTestEnv.tool("mail_change", MailTestEnv.make(f, scripts: s))
        let r = await change.handler(
            .object([
                "action": .string("move"), "ids": .array([.string("1001"), .string("1004")]),
                "mailbox": .string("archive"),
            ]))
        let text = MailTestEnv.text(r)
        #expect(text.contains("Moved to Archive: «Lease renewal»"), "\(text)")
        #expect(text.contains("its account has no mailbox archive"), "Gmail has none")
        #expect(Self.lastCall(s, MailScript.change) == ["move", "Archive", MailFixture.exchange, "Inbox", "1001"])
        let none = await change.handler(.object(["action": .string("move"), "id": .string("1001")]))
        #expect(none.isError)
        let bad = await change.handler(.object(["action": .string("archive"), "id": .string("1001")]))
        #expect(bad.isError && MailTestEnv.text(bad).contains("mark_read, mark_unread"))
    }

    @Test func goneMessagesAreReported() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = FakeScripts()
        s.answer = { _, _ in "missing 1001" }
        let r = try await MailTestEnv.tool("mail_change", MailTestEnv.make(f, scripts: s)).handler(
            .object(["action": .string("flag"), "id": .string("1001")]))
        #expect(r.isError && MailTestEnv.text(r).contains("moved or deleted"))
    }

    @Test func sendsAndConfirmsInSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts { _ in
            f.recordSent(id: 5000, box: .sent, subject: "Lunch", to: "sam@example.com")
            return "sent"
        }
        let send = try MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: s))
        let r = await send.handler(
            .object([
                "to": .array([.string("sam@example.com")]), "subject": .string("Lunch"), "text": .string("Noon?"),
                "from": .string("Work"),
            ]))
        let text = MailTestEnv.text(r)
        #expect(!r.isError, "\(text)")
        #expect(
            text.contains(
                "Sent to sam@example.com from owner@work.example: «Lunch». It is in Sent (Message-ID <m5000@example.com>"
            )
        )
        let args = try #require(Self.lastCall(s, MailScript.compose))
        #expect(
            Array(args.prefix(10)) == [
                "send", "new", "", "", "", "owner@work.example", "owner@work.example", "Lunch", "Noon?",
                "sam@example.com",
            ])
        #expect(r.activity == "Claude sent an email to sam@example.com: «Lunch»")
        #expect(s.calls.first { $0.script == MailScript.accounts }?.args == ["launch"])
    }

    @Test func unconfirmedIsNeverSentAgain() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let send = try MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: s, confirmWait: .milliseconds(200)))
        let r = await send.handler(
            .object(["to": .array([.string("sam@example.com")]), "subject": .string("Lunch"), "text": .string("Noon?")])
        )
        #expect(!r.isError && MailTestEnv.text(r).contains("isn't in Sent yet. Don't send it again"))
        #expect(s.calls.filter { $0.script == MailScript.compose }.count == 1)
        let t = FakeScripts()
        t.answer = { script, _ in
            if script == MailScript.compose { throw ScriptError.timedOut }
            return MailTestEnv.accountsAnswer
        }
        let late = try await MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: t)).handler(
            .object(["to": .array([.string("sam@example.com")]), "subject": .string("Lunch")]))
        #expect(!late.isError && MailTestEnv.text(late).contains("may or may not have gone"))
        #expect(t.calls.filter { $0.script == MailScript.compose }.count == 1)
    }

    @Test func refusesBeforeSending() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let send = try MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: s))
        let cases: [([String: JSONValue], String)] = [
            (["subject": .string("x")], "say who to send it to"),
            (["to": .array([.string("a@b.example")])], "give a subject"),
            (["to": .array([.string("Sarah")]), "subject": .string("x")], "isn't an email address"),
            (
                ["to": .array([.string("a@b.example")]), "subject": .string("x"), "from": .string("eve@evil.example")],
                "isn't one of Mail's accounts"
            ),
            (
                [
                    "to": .array([.string("a@b.example")]), "subject": .string("x"),
                    "attachments": .array([.string("/no/such/file")]),
                ],
                "no readable file"
            ),
        ]
        for (args, why) in cases {
            let r = await send.handler(.object(args))
            #expect(r.isError && MailTestEnv.text(r).contains(why), "\(why): \(MailTestEnv.text(r))")
        }
        #expect(!s.calls.contains { $0.script == MailScript.compose })
        let wrong = Self.scripts { _ in "sender Someone Else <other@example.com>" }
        let r = try await MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: wrong)).handler(
            .object([
                "to": .array([.string("a@b.example")]), "subject": .string("x"), "from": .string("owner@alias.example"),
            ]))
        #expect(r.isError && MailTestEnv.text(r).contains("Nothing was sent: Mail would have used Someone Else"))
        #expect(Self.lastCall(wrong, MailScript.compose)?[5] == "owner@alias.example", "the address asked for")
    }

    @Test func replyQuotesTheOriginalFromItsAccount() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts { _ in
            f.recordSent(id: 5001, box: .sent, subject: "Re: Lease renewal", to: "landlord@example.com")
            return "sent"
        }
        let r = try await MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: s)).handler(
            .object(["reply_to": .string("1001"), "text": .string("Thanks, that works."), "reply_all": .bool(true)]))
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        let args = try #require(Self.lastCall(s, MailScript.compose))
        #expect(
            Array(args.prefix(8)) == [
                "send", "replyall", MailFixture.exchange, "Inbox", "1001", "owner@work.example", "owner@work.example",
                "",
            ])
        #expect(args[8].hasPrefix("Thanks, that works.\n\nOn "))
        #expect(
            args[8].contains("Pat Landlord <landlord@example.com> wrote:\n\n> Hello,\n> The rent goes up in March."))
        #expect(MailTestEnv.text(r).contains("It is in Sent"))
    }

    @Test func gmailReplyGoesFromTheAddressItCameTo() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        _ = try await MailTestEnv.tool("mail_send", MailTestEnv.make(f, scripts: s, confirmWait: .zero)).handler(
            .object(["reply_to": .string("1004"), "text": .string("ok")]))
        let args = try #require(Self.lastCall(s, MailScript.compose))
        #expect(
            args[1] == "reply" && args[2] == MailFixture.gmail && args[3] == "INBOX"
                && args[5] == "owner@gmail.example")
    }

    @Test func forwardCarriesTheAttachments() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts()
        let env = try MailTestEnv.make(f, scripts: s, confirmWait: .zero)
        let r = try await MailTestEnv.tool("mail_send", env).handler(
            .object(["forward": .string("1003"), "to": .array([.string("bob@example.com")]), "text": .string("FYI")]))
        #expect(!r.isError)
        let args = try #require(Self.lastCall(s, MailScript.compose))
        #expect(args[1] == "forward" && args[3] == "Archive")
        #expect(args[8].contains("Begin forwarded message:") && args[8].contains("See attached."))
        let copies = args[13].split(separator: "\n").map(String.init)
        #expect(copies.map { URL(filePath: $0).lastPathComponent } == ["photo.png", "lease.pdf"])
        #expect(copies.allSatisfy { $0.hasPrefix(env.downloads.path) && FileManager.default.fileExists(atPath: $0) })
        #expect(MailTestEnv.text(r).contains("2 attachments"))
    }

    @Test func savesDrafts() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = Self.scripts { _ in "saved" }
        let r = try await MailTestEnv.tool("mail_change", MailTestEnv.make(f, scripts: s)).handler(
            .object([
                "action": .string("draft"), "to": .array([.string("sam@example.com")]), "subject": .string("Idea"),
            ]))
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(Self.lastCall(s, MailScript.compose)?.first == "draft")
        #expect(MailTestEnv.text(r).contains("Saved a draft to sam@example.com: «Idea»"))
        #expect(r.activity == "Claude saved a draft to sam@example.com: «Idea»" && r.made != nil)
    }

    @Test func accountsParse() {
        let list = MailAccounts.parse(MailTestEnv.accountsAnswer + "bad line\n")
        #expect(list.count == 2 && list[1].addresses == ["owner@gmail.example", "owner@alias.example"])
        #expect(list[0].label == "Work (owner@work.example)" && list[0].sentName == "Sent Items")
    }
}
