import Foundation
import Testing

@testable import Latchkey

/// Spec 008 changes and sending (plan D6, D7), with a stand-in for Mail's scripting: nothing is
/// ever sent.
@Suite struct MailWriteTests {
    /// Answers the accounts script like Mail and the change script with "ok" for each id.
    static func scripts() -> FakeScripts {
        let s = FakeScripts()
        s.answer = { script, args in
            if script == MailScript.accounts { return MailTestEnv.accountsAnswer }
            if script == MailScript.change {
                return stride(from: 4, to: args.count, by: 3).map { "ok \(args[$0])" }.joined(separator: "\n")
            }
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

    @Test func accountsParse() {
        let list = MailAccounts.parse(MailTestEnv.accountsAnswer + "bad line\n")
        #expect(list.count == 2 && list[1].addresses == ["owner@gmail.example", "owner@alias.example"])
        #expect(list[0].label == "Work (owner@work.example)" && list[0].sentName == "Sent Items")
        #expect(list[0].fullName == "Owner Person" && list[1].fullName == nil, "an older answer has no full name")
    }

    /// 2026-11-02: Mail took over 4 s, the list came from Mail's files without the Owner's name,
    /// and a forward to the Owner was refused. Sending waits as long as Mail's other scripts, and
    /// when Mail doesn't answer the last list it gave is used.
    @Test func accountsFallBackToMailsLastAnswer() async {
        let quick = FakeScripts()
        quick.answer = { _, _ in MailTestEnv.accountsAnswer }
        let slow = FakeScripts()
        slow.answer = { _, _ in throw ScriptError.timedOut }
        let accounts = MailAccounts(scripts: quick, launchScripts: slow, mayScript: { true })
        let t0 = Date()
        #expect(await accounts.list(launch: false, now: t0)?.first?.fullName == "Owner Person")
        quick.answer = { _, _ in throw ScriptError.timedOut }
        let later = await accounts.list(launch: true, now: t0.addingTimeInterval(3600))
        #expect(later?.first?.fullName == "Owner Person", "Mail's last answer, an hour old")
        #expect(slow.calls.count == 1 && quick.calls.count == 1, "sending asks with Mail's usual wait")
    }
}
