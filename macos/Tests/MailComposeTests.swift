import Foundation
import Testing

@testable import Latchkey

/// Plays Mail's compose window: never touches Mail, the screen, or the clipboard (spec 008 plan D6).
final class FakeComposeWindow: ComposeWindow, @unchecked Sendable {
    private let lock = NSLock()
    var shown = ComposeFields()
    private(set) var log: [String] = []
    /// The From addresses Mail offers.
    var senders = ["owner@work.example", "owner@gmail.example", "owner@alias.example"]
    /// Plays Mail marking inserted text as quoted.
    var quotesInsertedText = false
    /// Plays Mail failing to attach.
    var dropsFiles = false
    /// Plays someone typing into the To field meanwhile.
    var strayRecipient: String?
    /// Plays Mail (or someone) putting another address in place of the one added.
    var addsInstead: String?
    /// Plays Mail dropping its own first recipient when one is added.
    var dropsPrefilled = false
    /// Plays a change on the n-th read of the fields (counting from 1).
    var changeOnRead: (Int, @Sendable (inout ComposeFields) -> Void)?
    /// Plays a window that won't close.
    var stuck = false
    /// What pressing Send throws (Mail's window staying open, a sheet).
    var sendFails: ComposeFailure?
    var onSend: (@Sendable () -> Void)?
    private var reads = 0

    private func note(_ s: String) { lock.withLock { log.append(s) } }

    func fields() async throws -> ComposeFields {
        lock.withLock {
            reads += 1
            if let c = changeOnRead, c.0 == reads { c.1(&shown) }
            return shown
        }
    }

    func chooseSender(_ address: String) async throws -> Bool {
        note("sender \(address)")
        guard senders.contains(address) else { return false }
        lock.withLock { shown.from = "Owner – \(address)" }
        return true
    }

    func addRecipients(_ addresses: [String], to field: RecipientField) async throws {
        note("add \(field.rawValue) \(addresses.joined(separator: ","))")
        lock.withLock {
            let added = addsInstead.map { [$0] } ?? addresses
            switch field {
            case .to:
                if dropsPrefilled, !shown.to.isEmpty { shown.to.removeFirst() }
                shown.to += added
            case .cc: shown.cc += added
            case .bcc: shown.bcc += added
            }
        }
    }

    func insertText(_ text: String) async throws {
        note("insert text")
        lock.withLock {
            let lines = text.split(separator: "\n").map { (String($0), quotesInsertedText ? 1 : 0) }
            shown.body = lines + shown.body
            if let strayRecipient { shown.to.append(strayRecipient) }
        }
    }

    func attachFiles(_ files: [URL]) async throws {
        note("attach files \(files.map(\.lastPathComponent).joined(separator: ","))")
        guard !dropsFiles else { return }
        lock.withLock { shown.attachments += files.map { "\($0.lastPathComponent), 5 bytes" } }
    }

    func send() async throws {
        note("send")
        onSend?()
        if let sendFails { throw sendFails }
    }

    func saveDraft() async throws { note("save") }

    func discard() async -> Bool {
        // Runs to its end even when the call was cancelled.
        try? await Task.sleep(for: .milliseconds(20))
        note(Task.isCancelled ? "discard (cancelled)" : "discard")
        return !stuck
    }
}

final class FakeWindows: ComposeWindows, @unchecked Sendable {
    private let lock = NSLock()
    var blocked: String?
    let window = FakeComposeWindow()
    private(set) var opened: [ComposeOpening] = []
    private(set) var finished = 0
    /// The window a response opens with (Mail's own recipients, subject, quote).
    var response = ComposeFields()
    /// Plays Mail's "Automatically Bcc myself".
    var autoBcc: String?

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
            window.shown.bcc = list(c?.queryItems?.first { $0.name == "bcc" }?.value) + (autoBcc.map { [$0] } ?? [])
            window.shown.subject = c?.queryItems?.first { $0.name == "subject" }?.value ?? ""
            if window.shown.from.isEmpty { window.shown.from = "Owner – owner@gmail.example" }
        case .respond:
            window.shown = response
        }
        return window
    }

    func finish() async { lock.withLock { finished += 1 } }

    /// Plays an alert Mail shows in a window of its own.
    var alert: MailAlert?
    private(set) var alertChecks = 0
    func alert() async -> MailAlert? {
        lock.withLock {
            alertChecks += 1
            return alert
        }
    }
}

/// Plays the clipboard.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Data]]
    private var count = 0

    init(_ items: [[String: Data]]) { self.items = items }

    var changeCount: Int { lock.withLock { count } }
    var contents: [[String: Data]] { lock.withLock { items } }

    func snapshot() -> [[String: Data]] { contents }

    func replace(with new: [[String: Data]]) -> Int {
        lock.withLock {
            items = new
            count += 1
            return count
        }
    }

    /// Someone else copying.
    func copy(_ s: String) { _ = replace(with: [[ClipboardLoan.text: Data(s.utf8)]]) }
}

@Suite struct MailComposeTests {
    static func send(
        _ f: MailFixture, _ w: FakeWindows, _ args: [String: JSONValue], confirm: Duration = .seconds(2),
        contacts: any ContactsLookup = MailCapability.NoContacts()
    ) async throws -> ToolResult {
        let s = MailWriteTests.scripts()
        return try await MailTestEnv.tool(
            "mail_send", MailTestEnv.make(f, scripts: s, confirmWait: confirm, windows: w, contacts: contacts)
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
        defer { try? FileManager.default.removeItem(at: note) }
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
                "sender owner@work.example", "attach files \(note.lastPathComponent)", "insert text", "send",
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

    @Test func refusedWithoutAccessibility() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.blocked = AXMailWindows.needsAccessibility
        let r = try await Self.send(f, w, ["to": .array([.string("sam@example.com")]), "subject": .string("Hi")])
        #expect(
            r.isError && MailTestEnv.text(r).hasPrefix("Nothing was sent: Latchkey writes email in Mail's own window"))
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
        w.window.quotesInsertedText = true
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
        #expect(
            r1.isError && MailTestEnv.text(r1).contains("To field has eve@evil.example, which wasn't asked for"),
            "\(MailTestEnv.text(r1))")
        #expect(stray.window.log.last == "discard")

        let noFile = FakeWindows()
        noFile.window.dropsFiles = true
        let note = FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: note)
        defer { try? FileManager.default.removeItem(at: note) }
        let r2 = try await Self.send(f, noFile, base.merging(["attachments": .array([.string(note.path)])]) { $1 })
        #expect(r2.isError && MailTestEnv.text(r2).contains("attached 0 of 1 files"))
        #expect(noFile.window.log.last == "discard" && !noFile.window.log.contains("send"))

        let noSender = FakeWindows()
        noSender.window.senders = []
        let r3 = try await Self.send(f, noSender, base.merging(["from": .string("owner@alias.example")]) { $1 })
        #expect(r3.isError && MailTestEnv.text(r3).contains("offers no From address owner@alias.example"))
        #expect(noSender.window.log.last == "discard")

        // A name in place of an address counts only when it is that address's contact.
        let named = FakeWindows()
        named.window.strayRecipient = "Eve"
        let r4 = try await Self.send(f, named, base)
        #expect(r4.isError && MailTestEnv.text(r4).contains("To field has Eve, which wasn't asked for"))
    }

    @Test func aContactsNameStandsForItsAddress() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        // Mail shows a contact's name in the token.
        w.window.changeOnRead = (1, { $0.to = ["Bob Stone"] })
        let r = try await Self.send(
            f, w, ["to": .array([.string("bob@example.com")]), "subject": .string("Hi"), "text": .string("Hello")],
            confirm: .zero, contacts: MessagesFixture.FakeContacts())
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.window.log.contains("send"))
    }

    @Test func onlyTheOwnersOwnAddressMayBeAddedByMail() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let base: [String: JSONValue] = [
            "to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello"),
        ]
        // "Automatically Bcc myself" in Mail's settings.
        let auto = FakeWindows()
        auto.autoBcc = "owner@gmail.example"
        let ok = try await Self.send(f, auto, base, confirm: .zero)
        #expect(!ok.isError, "\(MailTestEnv.text(ok))")
        // Any other address in Bcc, from the start or later, is refused.
        let other = FakeWindows()
        other.autoBcc = "spy@evil.example"
        let r = try await Self.send(f, other, base)
        #expect(r.isError && MailTestEnv.text(r).contains("Bcc field has spy@evil.example"))
        #expect(other.window.log.last == "discard" && !other.window.log.contains("send"))
    }

    @Test func nothingChangesBetweenTheCheckAndSend() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        // Reads: 1 when it opened, 2 for the check, 3 just before Send.
        w.window.changeOnRead = (3, { $0.cc.append("eve@evil.example") })
        let r = try await Self.send(
            f, w, ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")])
        #expect(r.isError && MailTestEnv.text(r).contains("changed while Latchkey was checking"))
        #expect(!w.window.log.contains("send") && w.window.log.last == "discard")
    }

    @Test func aWindowThatWontCloseIsReported() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.window.quotesInsertedText = true
        w.window.stuck = true
        let r = try await Self.send(
            f, w, ["to": .array([.string("sam@example.com")]), "subject": .string("Hi"), "text": .string("Hello")])
        #expect(r.isError && MailTestEnv.text(r).contains("still open on the screen, unsent"))
        #expect(w.finished == 1)
    }

    @Test func aCancelledCallStillClosesTheWindow() async throws {
        let w = FakeWindows()
        let request = MailCompose.Request(
            opening: .new(mailto: URL(string: "mailto:sam@example.com?subject=Hi")!),
            to: [KnownAddress(address: "sam@example.com")], subject: "Hi", text: "Hello", files: [], draft: false)
        let task = Task { try await MailCompose.run(request, w, attachWait: .zero) }
        task.cancel()
        _ = try? await task.value
        #expect(!w.window.log.contains("send"), "a cancelled call never sends")
        #expect(w.window.log.last == "discard" && w.finished == 1, "\(w.window.log)")
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
        #expect(w.opened.map(\.withoutPlace) == [.respond(messageID: "<m1001@example.com>", kind: .reply)])
        #expect(w.opened.first?.place?.id == 1001, "Mail's scripting can find the original")
        #expect(w.window.log == ["insert text", "send"], "Mail's own From already is the account it came to")
        #expect(
            MailTestEnv.text(r).contains(
                "Sent to landlord@example.com from owner@work.example: «Re: Lease renewal». It is in Sent"))
    }

    /// Security review 2026-10-30: `message://` opens by Message-ID, which anyone can copy.
    @Test func aReplyWindowForAnotherMessageIsNeverSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let cases: [(ComposeFields, String)] = [
            (ComposeFields(to: ["eve@evil.example"], subject: "Re: Lease renewal"), "addressed to eve@evil.example"),
            (ComposeFields(to: ["Pat Landlord"], subject: "Re: Wire the deposit"), "its subject is"),
            (
                ComposeFields(to: ["Pat Landlord"], cc: ["eve@evil.example"], subject: "Re: Lease renewal"),
                "addressed to eve@evil.example"
            ),
            (ComposeFields(to: ["Pat Landlord"], bcc: ["eve@evil.example"], subject: "Re: Lease renewal"), "Bcc"),
            (ComposeFields(subject: "Re: Lease renewal"), "isn't addressed to landlord@example.com"),
        ]
        for (window, why) in cases {
            let w = FakeWindows()
            w.response = window
            let r = try await Self.send(f, w, ["reply_to": .string("1001"), "text": .string("Yes")])
            #expect(r.isError && MailTestEnv.text(r).contains(why), "\(why): \(MailTestEnv.text(r))")
            #expect(w.window.log == ["discard"], "nothing typed, nothing sent: \(w.window.log)")
            #expect(MailTestEnv.text(r).hasPrefix("Nothing was sent"))
        }
    }

    @Test func aCopiedMessageIDIsRefusedBeforeOpening() async throws {
        let f = try MailFixture()
        defer { f.close() }
        // Someone sent a message carrying 1001's Message-ID.
        f.add(
            4000, .inbox, ("eve@evil.example", "Pat Landlord"), "Lease renewal", 100, read: false,
            to: [("owner@work.example", "")], file: .plain("Reply to me"), messageID: "<M1001@example.com>")
        let w = FakeWindows()
        for args: [String: JSONValue] in [
            ["reply_to": .string("1001"), "text": .string("Yes")],
            ["forward": .string("4000"), "to": .array([.string("bob@example.com")])],
        ] {
            let r = try await Self.send(f, w, args)
            #expect(r.isError && MailTestEnv.text(r).contains("2 messages in Mail have that message's Message-ID"))
        }
        #expect(w.opened.isEmpty)
    }

    /// 2026-11-01: a second copy of the same message (same sender and subject, sent within
    /// minutes: Inbox and Sent of a message to oneself) doesn't block an answer; another
    /// sender's copy still does.
    @Test func aSecondCopyOfTheSameMessageCanBeAnswered() async throws {
        let f = try MailFixture()
        defer { f.close() }
        f.add(
            4001, .archive, ("landlord@example.com", "Pat Landlord"), "Lease renewal", 61, read: true,
            to: [("owner@work.example", "")], file: .plain("Hello"), messageID: "<M1001@example.com>")
        let store = try MailStore(root: f.root)
        #expect(try store.messagesSharing(messageID: "<m1001@example.com>") == 1)
        f.add(
            4002, .inbox, ("landlord@example.com", "Pat Landlord"), "Lease renewal", 200, read: true,
            to: [("owner@work.example", "")], file: .plain("Later"), messageID: "<M1001@example.com>")
        #expect(try store.messagesSharing(messageID: "<m1001@example.com>") == 3, "sent hours apart: not one message")
    }

    @Test func replyGoesToReplyTo() async throws {
        let f = try MailFixture()
        defer { f.close() }
        f.add(
            4001, .inbox, ("news@club.example", "Club"), "Meeting", 100, read: false,
            to: [("owner@work.example", "")], replyTo: "Club Desk <desk@club.example>", file: .plain("Come"))
        let w = FakeWindows()
        w.response = ComposeFields(to: ["Club Desk"], subject: "Re: Meeting", from: "Owner – owner@work.example")
        let r = try await Self.send(f, w, ["reply_to": .string("4001"), "text": .string("I'll come")], confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.window.log.contains("send"))
    }

    @Test func addedRecipientsAreExactlyTheOnesAsked() async throws {
        let f = try MailFixture()
        defer { f.close() }
        func reply(_ setUp: (FakeComposeWindow) -> Void, _ args: [String: JSONValue]) async throws -> (
            ToolResult, FakeWindows
        ) {
            let w = FakeWindows()
            w.response = ComposeFields(to: ["Pat Landlord"], subject: "Re: Lease renewal")
            setUp(w.window)
            let r = try await Self.send(
                f, w, ["reply_to": .string("1001"), "text": .string("Yes")].merging(args) { $1 }, confirm: .zero)
            return (r, w)
        }
        let asked: [String: JSONValue] = ["cc": .array([.string("bob@example.com")])]
        let (ok, okW) = try await reply({ _ in }, asked)
        #expect(okW.window.log.contains("add cc bob@example.com") && okW.window.log.contains("send"))
        _ = ok
        let (other, otherW) = try await reply({ $0.addsInstead = "BOB@evil.example" }, asked)
        #expect(MailTestEnv.text(other).contains("Cc field has BOB@evil.example, which wasn't asked for"))
        #expect(!otherW.window.log.contains("send"))
        let (dropped, _) = try await reply(
            { $0.dropsPrefilled = true }, ["to": .array([.string("bob@example.com")])])
        #expect(MailTestEnv.text(dropped).contains("To field no longer has Pat Landlord"))
        let (bcc, _) = try await reply({ $0.strayRecipient = nil }, ["bcc": .array([.string("bob@example.com")])])
        #expect(!bcc.isError, "\(MailTestEnv.text(bcc))")
        let (case1, _) = try await reply({ _ in }, ["to": .array([.string("Landlord@Example.com")])])
        #expect(!case1.isError, "an address Mail already has: \(MailTestEnv.text(case1))")
    }

    @Test func gmailReplyAllFromTheAddressItCameTo() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(to: ["Boss"], subject: "Re: Plan", from: "Owner – owner@alias.example")
        _ = try await Self.send(
            f, w, ["reply_to": .string("1004"), "reply_all": .bool(true), "text": .string("ok")], confirm: .zero)
        #expect(w.opened.map(\.withoutPlace) == [.respond(messageID: "<m1004@example.com>", kind: .replyAll)])
        #expect(w.opened.first?.place?.id == 1004, "Mail's scripting can find the original")
        #expect(w.window.log.first == "sender owner@gmail.example")
    }

    @Test func replyAllMayAddressTheOriginalsRecipientsOnly() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(to: ["Sarah Lee"], cc: ["Bob"], subject: "Re: Photos and lease")
        let r = try await Self.send(
            f, w, ["reply_to": .string("1003"), "reply_all": .bool(true), "text": .string("ok")], confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        let plain = FakeWindows()
        plain.response = ComposeFields(to: ["Sarah Lee"], cc: ["Bob"], subject: "Re: Photos and lease")
        let r2 = try await Self.send(f, plain, ["reply_to": .string("1003"), "text": .string("ok")])
        #expect(r2.isError && MailTestEnv.text(r2).contains("addressed to Bob"), "a plain reply goes to the sender")
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
        #expect(w.opened.map(\.withoutPlace) == [.respond(messageID: "<m1003@example.com>", kind: .forward)])
        #expect(w.opened.first?.place?.id == 1003, "Mail's scripting can find the original")
        #expect(w.window.log == ["add to bob@example.com", "insert text", "send"])
        #expect(MailTestEnv.text(r).contains("isn't in Sent yet. Don't send it again"))
        let none = try await Self.send(f, FakeWindows(), ["forward": .string("1003")])
        #expect(none.isError && MailTestEnv.text(none).contains("say who to send it to"))
    }

    /// Mail shows the account's full name, not the address, for the Owner's own address (seen live
    /// 2026-11-01 with the lid closed); a name that is no one's asked address is still refused.
    @Test func ownAddressShownAsTheAccountsNameIsAccepted() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let w = FakeWindows()
        w.response = ComposeFields(
            subject: "Fwd: Photos and lease", attachments: ["photo.png, 1 KB", "lease.pdf, 2 KB"])
        w.window.addsInstead = "Owner Person"
        let r = try await Self.send(
            f, w, ["forward": .string("1003"), "to": .array([.string("owner@work.example")]), "text": .string("FYI")],
            confirm: .zero)
        #expect(!r.isError, "\(MailTestEnv.text(r))")
        #expect(w.window.log.last == "send")
        let other = FakeWindows()
        other.response = w.response
        other.window.addsInstead = "Owner Person"
        let r2 = try await Self.send(
            f, other, ["forward": .string("1003"), "to": .array([.string("bob@example.com")]), "text": .string("FYI")],
            confirm: .zero)
        #expect(r2.isError && MailTestEnv.text(r2).contains("Owner Person, which wasn't asked for"))
        #expect(!other.window.log.contains("send"))
    }

    @Test func aForwardOfAnotherMessageIsNeverSent() async throws {
        let f = try MailFixture()
        defer { f.close() }
        for (window, why) in [
            (
                ComposeFields(subject: "Fwd: Photos and lease", attachments: ["payroll.xlsx, 9 KB"]),
                "attachment the message doesn't have"
            ),
            // Security review 2026-10-30: a name that only starts like one of the original's.
            (
                ComposeFields(subject: "Fwd: Photos and lease", attachments: ["lease.pdf.exe, 2 KB"]),
                "attachment the message doesn't have"
            ),
            (ComposeFields(subject: "Fwd: Salaries"), "its subject is"),
            (ComposeFields(to: ["eve@evil.example"], subject: "Fwd: Photos and lease"), "addressed to eve"),
        ] {
            let w = FakeWindows()
            w.response = window
            let r = try await Self.send(
                f, w, ["forward": .string("1003"), "to": .array([.string("bob@example.com")])])
            #expect(r.isError && MailTestEnv.text(r).contains(why), "\(why): \(MailTestEnv.text(r))")
            #expect(w.window.log == ["discard"])
        }
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

    // MARK: the clipboard (security review 2026-10-30)

    @Test func theClipboardIsLentMarkedAndGivenBack() {
        let owner: [[String: Data]] = [
            ["public.utf8-plain-text": Data("owner's".utf8), "public.rtf": Data("{rtf}".utf8)]
        ]
        let pb = FakePasteboard(owner)
        let loan = ClipboardLoan(pb, items: ClipboardLoan.text("Hello"))
        let lent = pb.contents
        #expect(lent.count == 1 && lent[0][ClipboardLoan.text] == Data("Hello".utf8))
        for mark in [
            "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
        ] {
            #expect(lent[0][mark] != nil, "\(mark)")
        }
        #expect(loan.intact)
        loan.giveBack()
        #expect(pb.contents == owner)
        loan.giveBack()
        #expect(pb.contents == owner, "given back once")
        let files = ClipboardLoan(pb, items: ClipboardLoan.files([URL(filePath: "/tmp/a b.txt")]))
        #expect(pb.contents.first?[ClipboardLoan.fileURL] == Data("file:///tmp/a%20b.txt".utf8))
        files.giveBack()
        #expect(pb.contents == owner)
    }

    @Test func aCopyMeanwhileStopsThePasteAndIsKept() {
        let pb = FakePasteboard([["public.utf8-plain-text": Data("old".utf8)]])
        let loan = ClipboardLoan(pb, items: ClipboardLoan.text("Hello"))
        pb.copy("the Owner's new copy")
        #expect(!loan.intact, "checked right before Paste")
        loan.giveBack()
        #expect(pb.contents == [[ClipboardLoan.text: Data("the Owner's new copy".utf8)]])
    }
}

extension ComposeOpening {
    /// The opening without where the original is, to compare with what a test expects.
    var withoutPlace: ComposeOpening {
        if case .respond(let id, let kind, _) = self { return .respond(messageID: id, kind: kind) }
        return self
    }
    var place: MessagePlace? {
        if case .respond(_, _, let place) = self { return place }
        return nil
    }
}
