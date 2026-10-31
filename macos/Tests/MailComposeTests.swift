import Foundation
import Testing

@testable import Latchkey

/// Plays Mail's compose window: never touches Mail or the screen (spec 008 plan D6).
final class FakeComposeWindow: ComposeWindow, @unchecked Sendable {
    private let lock = NSLock()
    var shown = ComposeFields()
    private(set) var log: [String] = []
    /// The From addresses Mail offers.
    var senders = ["owner@work.example", "owner@gmail.example", "owner@alias.example"]
    /// Plays Mail marking pasted text as quoted.
    var quotesPastedText = false
    /// Plays Mail failing to attach.
    var dropsFiles = false
    /// Plays someone typing into the To field meanwhile.
    var strayRecipient: String?
    var onSend: (@Sendable () -> Void)?

    private func note(_ s: String) { lock.withLock { log.append(s) } }

    func fields() async throws -> ComposeFields { lock.withLock { shown } }

    func chooseSender(_ address: String) async throws -> Bool {
        note("sender \(address)")
        guard senders.contains(address) else { return false }
        lock.withLock { shown.from = "Owner – \(address)" }
        return true
    }

    func addRecipients(_ addresses: [String], to field: RecipientField) async throws {
        note("add \(field.rawValue) \(addresses.joined(separator: ","))")
        lock.withLock {
            switch field {
            case .to: shown.to += addresses
            case .cc: shown.cc += addresses
            case .bcc: shown.bcc += addresses
            }
        }
    }

    func pasteText(_ text: String) async throws {
        note("paste text")
        lock.withLock {
            let lines = text.split(separator: "\n").map { (String($0), quotesPastedText ? 1 : 0) }
            shown.body = lines + shown.body
            if let strayRecipient { shown.to.append(strayRecipient) }
        }
    }

    func pasteFiles(_ files: [URL]) async throws {
        note("paste files \(files.map(\.lastPathComponent).joined(separator: ","))")
        guard !dropsFiles else { return }
        lock.withLock { shown.attachments += files.map { "\($0.lastPathComponent), 5 bytes" } }
    }

    func send() async throws {
        note("send")
        onSend?()
    }

    func saveDraft() async throws { note("save") }

    func discard() async { note("discard") }
}

final class FakeWindows: ComposeWindows, @unchecked Sendable {
    private let lock = NSLock()
    var blocked: String?
    let window = FakeComposeWindow()
    private(set) var opened: [ComposeOpening] = []
    private(set) var finished = 0
    /// The window a response opens with (Mail's own recipients, subject, quote).
    var response = ComposeFields()

    func unavailable() async -> String? { blocked }

    func open(_ how: ComposeOpening) async throws -> any ComposeWindow {
        lock.withLock { opened.append(how) }
        switch how {
        case .new(let url):
            // Mail reads the mailto: link's recipients and subject.
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let list: (String?) -> [String] = { ($0 ?? "").split(separator: ",").map(String.init) }
            window.shown.to = list(c?.path)
            window.shown.cc = list(c?.queryItems?.first { $0.name == "cc" }?.value)
            window.shown.bcc = list(c?.queryItems?.first { $0.name == "bcc" }?.value)
            window.shown.subject = c?.queryItems?.first { $0.name == "subject" }?.value ?? ""
            if window.shown.from.isEmpty { window.shown.from = "Owner – owner@gmail.example" }
        case .respond:
            window.shown = response
        }
        return window
    }

    func finish() async { lock.withLock { finished += 1 } }
}

@Suite struct MailComposeTests {
    static func send(_ f: MailFixture, _ w: FakeWindows, _ args: [String: JSONValue], confirm: Duration = .seconds(2))
        async throws -> ToolResult
    {
        let s = MailWriteTests.scripts()
        return try await MailTestEnv.tool(
            "mail_send", MailTestEnv.make(f, scripts: s, confirmWait: confirm, windows: w)
        )
        .handler(.object(args))
    }

    @Test func newMessageGoesThroughTheWindowAndIsConfirmed() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.window.onSend = {
            f.recordSent(id: 5000, box: .sent, subject: "Lunch & co?", to: "sam@example.com", attachments: 1)
        }
        let note = FileManager.default.temporaryDirectory.appending(path: "note-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: note)
        let r = try await Self.send(
            f, w,
            [
                "to": .array([.string("sam@example.com")]), "subject": .string("Lunch & co?"),
                "text": .string("Noon?\nAt the usual place."), "from": .string("Work"),
                "attachments": .array([.string(note.path)]),
            ])
        let text = MailTestEnv.text(r)
        #expect(!r.isError, "\(text)")
        guard case .new(let url) = try #require(w.opened.first) else { Issue.record("not a new message"); return }
        #expect(url.absoluteString == "mailto:sam@example.com?subject=Lunch%20%26%20co%3F", "no text in the link")
        #expect(
            w.window.log == [
                "sender owner@work.example", "paste text", "paste files \(note.lastPathComponent)", "send",
            ])
        #expect(w.finished == 1)
        #expect(
            text.contains(
                "Sent to sam@example.com from owner@work.example: «Lunch & co?», 1 attachment. It is in Sent (Message-ID <m5000@example.com>"
            ))
        #expect(r.activity == "Claude sent an email to sam@example.com: «Lunch & co?»")
    }

    @Test func mailtoCarriesRecipientsAndSubjectOnly() throws {
        let url = try #require(
            MailCompose.mailto(
                to: ["a@x.example", "b+tag@x.example"], cc: ["c@x.example"], bcc: ["d@x.example"],
                subject: "Café & bar=1?"))
        #expect(
            url.absoluteString
                == "mailto:a@x.example,b%2Btag@x.example?cc=c@x.example&bcc=d@x.example&subject=Caf%C3%A9%20%26%20bar%3D1%3F"
        )
    }

    @Test func refusedWhileTheScreenIsOffOrLocked() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.blocked = "Nothing was sent: Latchkey can't write email while the Mac's screen is off or locked."
        let r = try await Self.send(f, w, ["to": .array([.string("sam@example.com")]), "subject": .string("Hi")])
        #expect(r.isError && MailTestEnv.text(r).hasPrefix("Nothing was sent: Latchkey can't write email while"))
        #expect(w.opened.isEmpty && w.window.log.isEmpty, "no window, no scripting")
        let draft = try await MailTestEnv.tool(
            "mail_change", MailTestEnv.make(f, scripts: MailWriteTests.scripts(), windows: w)
        )
        .handler(.object(["action": .string("draft"), "subject": .string("Idea")]))
        #expect(draft.isError && MailTestEnv.text(draft).hasPrefix("No draft was saved"))
    }

    @Test func textMarkedAsQuotedIsNeverSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.window.quotesPastedText = true
        let r = try await Self.send(
            f, w, ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")])
        #expect(r.isError && MailTestEnv.text(r).contains("marked it as quoted"))
        #expect(w.window.log.last == "discard" && !w.window.log.contains("send") && w.finished == 1)
    }

    @Test func everyFieldIsCheckedBeforeSending() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let base: [String: JSONValue] = [
            "to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello"),
        ]
        let stray = FakeWindows()
        stray.window.strayRecipient = "eve@evil.example"
        let r1 = try await Self.send(f, stray, base)
        #expect(r1.isError && MailTestEnv.text(r1).contains("To field shows 2 recipients"), "\(MailTestEnv.text(r1))")
        #expect(stray.window.log.last == "discard")

        let noFile = FakeWindows()
        noFile.window.dropsFiles = true
        let note = FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: note)
        let r2 = try await Self.send(f, noFile, base.merging(["attachments": .array([.string(note.path)])]) { $1 })
        #expect(r2.isError && MailTestEnv.text(r2).contains("attached 0 of 1 files"))
        #expect(noFile.window.log.last == "discard" && !noFile.window.log.contains("send"))

        let noSender = FakeWindows()
        noSender.window.senders = []
        let r3 = try await Self.send(f, noSender, base.merging(["from": .string("owner@alias.example")]) { $1 })
        #expect(r3.isError && MailTestEnv.text(r3).contains("offers no From address owner@alias.example"))
    }

    @Test func replyUsesMailsReplyOnTheOriginal() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(
            to: ["Pat Landlord"], subject: "Re: Lease renewal", from: "Owner – owner@work.example",
            body: [("On Oct 22, Pat wrote:", 1), ("The rent goes up in March.", 2)])
        w.window.onSend = {
            f.recordSent(id: 5001, box: .sent, subject: "Re: Lease renewal", to: "landlord@example.com")
        }
        let r = try await Self.send(f, w, ["reply_to": .string("1001"), "text": .string("Thanks, that works.")])
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.opened == [.respond(messageID: "<m1001@example.com>", kind: .reply)])
        #expect(w.window.log == ["paste text", "send"], "Mail's own From already is the account it came to")
        #expect(
            MailTestEnv.text(r).contains(
                "Sent to landlord@example.com from owner@work.example: «Re: Lease renewal». It is in Sent"))
    }

    @Test func gmailReplyAllFromTheAddressItCameTo() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(to: ["Boss"], subject: "Re: Plan", from: "Owner – owner@alias.example")
        _ = try await Self.send(
            f, w, ["reply_to": .string("1004"), "reply_all": .bool(true), "text": .string("ok")], confirm: .zero)
        #expect(w.opened == [.respond(messageID: "<m1004@example.com>", kind: .replyAll)])
        #expect(w.window.log.first == "sender owner@gmail.example")
    }

    @Test func forwardAddsItsRecipients() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(
            subject: "Fwd: Photos and lease", from: "Owner – owner@work.example",
            attachments: ["photo.png, 1 KB", "lease.pdf, 2 KB"])
        let r = try await Self.send(
            f, w, ["forward": .string("1003"), "to": .array([.string("bob@example.com")]), "text": .string("FYI")],
            confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.opened == [.respond(messageID: "<m1003@example.com>", kind: .forward)])
        #expect(w.window.log == ["add to bob@example.com", "paste text", "send"])
        #expect(MailTestEnv.text(r).contains("isn't in Sent yet. Don't send it again"))
        let none = try await Self.send(f, FakeWindows(), ["forward": .string("1003")])
        #expect(none.isError && MailTestEnv.text(none).contains("say who to send it to"))
    }

    @Test func draftsAreSavedNotSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        let r = try await MailTestEnv.tool(
            "mail_change", MailTestEnv.make(f, scripts: MailWriteTests.scripts(), windows: w)
        )
        .handler(
            .object([
                "action": .string("draft"), "to": .array([.string("sam@example.com")]), "subject": .string("Idea"),
            ]))
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.window.log == ["save"])
        #expect(MailTestEnv.text(r).contains("Saved a draft to sam@example.com: «Idea»"))
        #expect(r.activity == "Claude saved a draft to sam@example.com: «Idea»" && r.made != nil)
    }

    @Test func refusesBeforeOpeningAWindow() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
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
                ], "no readable file"
            ),
        ]
        for (args, why) in cases {
            let r = try await Self.send(f, w, args)
            #expect(r.isError && MailTestEnv.text(r).contains(why), "\(why): \(MailTestEnv.text(r))")
        }
        #expect(w.opened.isEmpty)
    }

    @Test func oneEmailAtATime() async throws {
        let q = ComposeQueue()
        let first = Task {
            try await q.run {
                try await Task.sleep(for: .milliseconds(300)); return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: ComposeFailure.self) { try await q.run { 2 } }
        #expect(try await first.value == 1)
        #expect(try await q.run { 3 } == 3)
    }

    @Test func noScriptComposesMail() {
        #expect(!MailScript.change.contains("outgoing message"))
        #expect(!MailScript.accounts.contains("outgoing message"))
    }
}
