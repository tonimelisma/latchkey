import Foundation
import Testing

@testable import Latchkey

/// Spec 008 FR-835 to FR-837: email queued while the Mac is locked goes out at the next unlock.
@Suite struct MailQueueTests {
    func queue() -> (MailQueue, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString)/mail-queue.json")
        return (MailQueue(file: file), file)
    }

    let message: JSONValue = .object([
        "action": .string("add"), "to": .array([.string("sam@example.com")]), "subject": .string("Lunch"),
        "text": .string("Noon?"),
    ])

    @Test func addsListsAndCancels() async throws {
        let (q, file) = queue()
        let added = await MailCapability.queue(message, q)
        #expect(!added.isError, "\(added.content.jsonText)")
        #expect(added.content.jsonText.contains("Queued «Lunch» to sam@example.com (id q1)"))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600, "only the Owner's account reads it")
        let stored = try #require(await q.items().first)
        #expect(stored.args["action"] == nil, "kept as mail_send's inputs")
        let list = await MailCapability.queue(.object(["action": .string("list")]), q)
        #expect(list.content.jsonText.contains("q1: «Lunch» to sam@example.com"))
        let cancelled = await MailCapability.queue(.object(["action": .string("cancel"), "id": .string("q1")]), q)
        #expect(!cancelled.isError)
        #expect(await q.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "an empty queue leaves no file")
        let unknown = await MailCapability.queue(.object(["action": .string("cancel"), "id": .string("q9")]), q)
        #expect(unknown.isError)
    }

    @Test func anAddressAsTextIsTaken() async {
        let (q, _) = queue()
        let r = await MailCapability.queue(
            .object([
                "action": .string("add"), "to": .string("sam@example.com, bob@example.com"),
                "subject": .string("Hi"),
            ]), q)
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(await q.items().first?.args["to"] == .array([.string("sam@example.com"), .string("bob@example.com")]))
    }

    @Test func refusesWhatCouldNeverBeSent() async {
        let (q, _) = queue()
        let nobody = await MailCapability.queue(.object(["action": .string("add"), "subject": .string("Hi")]), q)
        #expect(nobody.isError && nobody.content.jsonText.contains("say who it goes to"))
        let missing = await MailCapability.queue(
            .object([
                "action": .string("add"), "to": .array([.string("a@example.com")]),
                "attachments": .array([.string("/no/such/file.pdf")]),
            ]), q)
        #expect(missing.isError && missing.content.jsonText.contains("no readable file"))
        #expect(await q.items().isEmpty)
    }

    @Test func queuedMessagesAreSentOldestFirstAndRemoved() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let (q, _) = queue()
        _ = await MailCapability.queue(message, q)
        _ = await MailCapability.queue(
            .object([
                "action": .string("add"), "to": .array([.string("bob@example.com")]), "subject": .string("Second"),
                "text": .string("Hi"),
            ]), q)
        let w = FakeWindows()
        let env = try MailTestEnv.make(f, scripts: MailWriteTests.scripts(), confirmWait: .zero, windows: w)
        let reports = Locked<[String]>([])
        await MailCapability.sendQueued(q, env: env) { item, _ in reports.mutate { $0.append(item.summary) } }
        #expect(reports.value == ["«Lunch» to sam@example.com", "«Second» to bob@example.com"])
        #expect(w.opened.count == 2, "each went through Mail's window")
        #expect(await q.items().isEmpty)
    }

    /// Security review 2026-11-02: paused, unpaired, Mail turned down, or locked again: the rest waits.
    @Test func sendingStopsWhenNoLongerAllowed() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let (q, _) = queue()
        _ = await MailCapability.queue(message, q)
        _ = await MailCapability.queue(message, q)
        let w = FakeWindows()
        let env = try MailTestEnv.make(f, scripts: MailWriteTests.scripts(), confirmWait: .zero, windows: w)
        let asked = Locked(0)
        await MailCapability.sendQueued(
            q, env: env,
            allowed: {
                asked.mutate { $0 += 1 }
                return asked.value == 1
            }
        ) { _, _ in }
        #expect(w.opened.count == 1)
        #expect(await q.items().count == 1, "the second stays queued")
    }

    /// FR-838: Mail froze on 2026-11-02, the send failed, and the queue lost the message.
    @Test func aTryThatSentNothingKeepsItQueuedUntilTheLastTry() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let (q, _) = queue()
        _ = await MailCapability.queue(message, q)
        let w = FakeWindows()
        w.blocked = "Nothing was sent: Mail didn't open a new message window."
        let env = try MailTestEnv.make(f, scripts: MailWriteTests.scripts(), confirmWait: .zero, windows: w)
        let outcomes = Locked<[MailCapability.QueuedOutcome]>([])
        for _ in 1...MailQueue.tries {
            await MailCapability.sendQueued(q, env: env) { _, o in outcomes.mutate { $0.append(o) } }
            let list = await MailCapability.queue(.object(["action": .string("list")]), q)
            if outcomes.value.count == 1 {
                #expect(list.plainText.contains("tried 1 of 3 times, last: Nothing was sent: Mail didn't open"))
            }
        }
        let why = "Nothing was sent: Mail didn't open a new message window."
        #expect(outcomes.value == [.willRetry(why), .willRetry(why), .dropped(why)], "one try per round")
        #expect(await q.items().isEmpty, "given up after the last try")
    }

    /// Security review 2026-11-02: after Send was pressed Mail may have sent it; trying again
    /// could send it twice.
    @Test func aFailureAfterSendIsNeverTriedAgain() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let (q, _) = queue()
        _ = await MailCapability.queue(message, q)
        let w = FakeWindows()
        w.window.sendFails = ComposeFailure(message: "Mail's window stayed open after Send", afterSend: true)
        let env = try MailTestEnv.make(f, scripts: MailWriteTests.scripts(), confirmWait: .zero, windows: w)
        let outcomes = Locked<[MailCapability.QueuedOutcome]>([])
        await MailCapability.sendQueued(q, env: env) { _, o in outcomes.mutate { $0.append(o) } }
        guard case .dropped(let why) = try #require(outcomes.value.first) else {
            Issue.record("kept for another try: \(outcomes.value)")
            return
        }
        #expect(why.hasPrefix("Mail may not have sent it"), "never «Nothing was sent»")
        #expect(await q.items().isEmpty)
    }

    /// Security review 2026-11-02: a message queued while another is being tried gets an id of
    /// its own, so cancelling one can't hit the other.
    @Test func anIdBeingSentIsNotGivenOut() async throws {
        let (q, _) = queue()
        let first = try await q.add(.object([:]), summary: "first")
        let taken = try #require(try await q.take(first.id))
        let second = try await q.add(.object([:]), summary: "second")
        #expect(second.id != first.id)
        try await q.putBack(taken)
        #expect(Set(await q.items().map(\.id)).count == 2)
    }

    @Test func notificationsAreSentences() {
        let item = MailQueue.Item(
            id: "q1", created: Date(), args: .object([:]), summary: "«Lunch» to sam@example.com", failed: 1,
            lastError: nil)
        let sent = AppModel.queuedMailNote(item, .sent)
        #expect(sent.title == "Queued email sent" && sent.body == "«Lunch» to sam@example.com")
        let retry = AppModel.queuedMailNote(item, .willRetry("Nothing was sent: Mail didn't open a new message window"))
        #expect(retry.title == "Queued email not sent yet")
        #expect(
            retry.body
                == "«Lunch» to sam@example.com: Mail didn't open a new message window. Latchkey tries again in five minutes, or the next time you unlock the Mac."
        )
        var last = item
        last.failed = 3
        let dropped = AppModel.queuedMailNote(last, .dropped("Nothing was sent: Mail didn't answer."))
        #expect(
            dropped.body.hasSuffix(
                "Mail didn't answer. It is no longer queued after 3 tries; Claude can send it again."))
        #expect(!dropped.body.contains("{"), "no raw answer")
    }

    @Test func theLockedRefusalPointsToTheQueue() {
        #expect(AXMailWindows.whileLocked.contains("mail_queue"))
    }
}
