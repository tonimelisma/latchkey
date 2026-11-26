import Foundation
import Testing

@testable import Latchkey

/// Automated checks for regression cases in docs/regression-coverage.md ("regressions"
/// group, batch D): each test names its case and fails if that case's fix is undone.
@Suite struct RegressionOtherDTests {
    /// The App folder's Swift sources, for the checks that read code (like
    /// `AuditTrailTests.noCodeDeletesActivityEntries`).
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App")
        .standardizedFileURL

    static func sources(in folders: [String]) throws -> [(String, String)] {
        var out: [(String, String)] = []
        for folder in folders {
            let dir = app.appendingPathComponent(folder)
            let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            for file in files {
                out.append(
                    ("\(folder)/\(file)", try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)))
            }
        }
        return out
    }

    // MARK: regressions.notes_unknown_id_plain

    /// 2026-11-05/06: a note id Notes no longer had leaked Notes' raw scripting error
    /// ("Can't get note id "x-coredata://..." (-1728)"). The answer says plainly there is no such
    /// note and to search with notes_find, and Notes' scripting is never asked.
    static let goneID = "x-coredata://00000000-0000-0000-0000-000000000000/ICNote/p1"

    @Test func aNoteIdNotesNoLongerHasIsSaidPlainly() async throws {
        let s = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        fake.answer = { _, args in
            throw ScriptError.failed(
                "execution error: Notes got an error: Can't get note id \"\(args.first ?? "")\". (-1728)")
        }
        let read = try #require(
            NotesCapability.readTools(store: { s }, scripts: fake).first { $0.tool.name == "notes_read" })
        let r = await read.handler(.object(["id": .string(Self.goneID)]))
        #expect(r.isError)
        let t = resultText(r)
        #expect(t.contains("There is no note with id"), "\(t)")
        #expect(t.contains("notes_find"), "\(t)")
        #expect(!t.contains("-1728") && !t.contains("Can't get") && !t.contains("execution error"), "\(t)")

        let change = try #require(
            NotesCapability.writeTools(store: { s }, scripts: fake).first { $0.tool.name == "notes_change" })
        let asks: [[String: JSONValue]] = [
            ["action": .string("append"), "id": .string(Self.goneID), "text": .string("x")],
            ["action": .string("rename"), "id": .string(Self.goneID), "title": .string("x")],
            ["action": .string("move"), "id": .string(Self.goneID), "folder": .string("Trips")],
            ["action": .string("delete"), "id": .string(Self.goneID)],
        ]
        for ask in asks {
            let c = await change.handler(.object(ask))
            let ct = resultText(c)
            #expect(c.isError, "\(ask)")
            #expect(ct.contains("There is no note with id") && ct.contains("notes_find"), "\(ask): \(ct)")
            #expect(!ct.contains("-1728") && !ct.contains("Can't get"), "\(ask): \(ct)")
        }
        #expect(fake.calls.isEmpty, "Notes' scripting was never asked about a note its database doesn't have")
    }

    /// The same through Notes' scripting, used for a database layout Latchkey doesn't know: Notes'
    /// -1728 is "no such note", not "Notes reported an error: Can't get note id …" (2026-11-24).
    @Test func aGoneNoteReadThroughNotesScriptingIsNoSuchNote() async throws {
        let fake = FakeScripts()
        fake.answer = { _, args in
            throw ScriptError.failed(
                "execution error: Notes got an error: Can't get note id \"\(args.first ?? "")\". (-1728)")
        }
        await #expect {
            _ = try await NotesScriptReader(scripts: fake).read(id: Self.goneID)
        } throws: { error in
            guard case NotesStore.Failure.noSuchNote(let id) = error else { return false }
            return id == Self.goneID
        }
        // Any other failure of Notes is still told as it is.
        fake.answer = { _, _ in throw ScriptError.failed("execution error: Notes got an error: busy (-600)") }
        await #expect(throws: ScriptError.failed("execution error: Notes got an error: busy (-600)")) {
            _ = try await NotesScriptReader(scripts: fake).read(id: Self.goneID)
        }
    }

    // MARK: regressions.calendar_repeat_said

    /// 2026-11-02 (0.8.85): making an event repeat set the repeat, but the update's answer didn't
    /// say so, so a check couldn't confirm it. The answer itself says how it repeats now.
    @Test func makingAnEventRepeatIsSaidInTheAnswer() async throws {
        let backend = RepeatingEventsD()
        let la = CalendarDatesTests.la
        let start = try CalendarDates.parse("2026-11-25T06:00", zone: la).date
        backend.inner.stored.append(
            EventInfo(
                identifier: "X0", title: "Check repeat", start: start, end: start.addingTimeInterval(3600),
                allDay: false, calendar: "Home", calendarID: "C-HOME"))
        let change = try #require(
            CalendarCapability.writeTools(backend: backend, zone: { la }).first { $0.tool.name == "calendar_change" })
        let id = backend.inner.stored[0].id
        let r = await change.handler(
            .object([
                "action": .string("update"), "id": .string(id), "repeat": .string("daily"),
                "repeat_count": .number(3),
            ]))
        #expect(!r.isError, "\(resultText(r))")
        #expect(backend.inner.lastDraft?.repeats == .set(Repeat(frequency: "daily", interval: 1, count: 3)))
        #expect(resultText(r).contains(", repeats every day, 3 times"), "\(resultText(r))")

        // And taking the repeat off is said too.
        let newID = backend.inner.stored[0].id
        let off = await change.handler(
            .object([
                "action": .string("update"), "id": .string(newID), "repeat": .string("none"), "span": .string("future"),
            ]))
        #expect(!off.isError, "\(resultText(off))")
        #expect(resultText(off).contains("no longer repeats"), "\(resultText(off))")
    }

    @Test func theRepeatPhraseNamesFrequencyAndCount() {
        let la = CalendarDatesTests.la
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var e = EventInfo(
            identifier: "X1", title: "Yoga", start: start, end: start.addingTimeInterval(3600), allDay: false,
            calendar: "Home", calendarID: "C-HOME")
        #expect(CalendarCapability.repeating(e, zone: la) == "")
        e.repeats = Repeat(frequency: "daily", count: 3)
        #expect(CalendarCapability.repeating(e, zone: la) == ", repeats every day, 3 times")
        var old = e
        e.repeats = nil
        #expect(CalendarCapability.repeating(e, zone: la, was: old) == ", no longer repeats")
        old.repeats = nil
        #expect(CalendarCapability.repeating(e, zone: la, was: old) == "")
    }

    // MARK: regressions.relay_bad_numbers_refused

    /// Security review 2026-10-24: bad numbers in tool arguments crashed the Mac app. notes_find
    /// with limit -1 or 1.5 is answered with an error about the number, listing no notes.
    @Test(arguments: [JSONValue.number(-1), .number(1.5)])
    func aBadLimitIsAnErrorAboutTheNumber(_ bad: JSONValue) async throws {
        let s = try NotesStore(url: NotesFixture.make())
        let search = try #require(NotesCapability.readOperations(store: { s }).first { $0.tool.name == "notes_search" })
        let r = await search.handler(.object(["query": .string(""), "limit": bad]))
        #expect(r.isError, "\(resultText(r))")
        #expect(resultText(r).contains("limit"), "\(resultText(r))")
        #expect(r.structuredContent?["notes"] == nil, "no notes listed")
        #expect(!resultText(r).contains("Groceries") && !resultText(r).contains("Lisbon"), "\(resultText(r))")

        let find = try #require(NotesCapability.readTools(store: { s }).first { $0.tool.name == "notes_find" })
        let found = await find.handler(.object(["query": .string("trip"), "limit": bad]))
        #expect(found.isError, "\(resultText(found))")
        #expect(resultText(found).contains("limit"), "\(resultText(found))")
        #expect(!resultText(found).contains("Lisbon"), "\(resultText(found))")
        // With no query, notes_find also lists the folders; the bad number is still named.
        let bare = await find.handler(.object(["limit": bad]))
        #expect(bare.isError, "an error, not the folders beside it: \(resultText(bare))")
        #expect(resultText(bare).contains("limit"), "\(resultText(bare))")
        #expect(!resultText(bare).contains("Groceries"), "\(resultText(bare))")
    }

    // MARK: regressions.machines_text_results_with_state_line

    /// Live check 2026-10-22: results carried structured content, and Claude's apps showed that
    /// instead of the text, so shell output, the state line, and the "not instructions" marking
    /// vanished. Every result the app sends the relay is text only.
    @Test func everyResultSentToTheRelayIsTextOnly() throws {
        var found = 0
        for (file, text) in try Self.sources(in: ["."]) {
            var rest = text[...]
            while let r = rest.range(of: "CallResult(") {
                let after = rest[r.upperBound...]
                let end = after.range(of: "isError:")?.lowerBound ?? after.endIndex
                let call = after[..<end]
                #expect(call.contains("structuredContent: nil"), "\(file): CallResult(\(call)")
                found += 1
                rest = after
            }
        }
        #expect(found >= 1, "the app builds the results it sends")
    }

    // MARK: regressions.never_disturb_front_app (Latchkey's part)

    /// 2026-11-02 to 2026-11-07: Notes, Mail, and Messages windows came forward while the Owner
    /// worked; since 2026-11-07 nothing comes to the front while unlocked (Constitution IV). The
    /// scripts background capabilities send never bring their app forward, type, or use the
    /// clipboard. (Safari's tab scripts and computer control are Toni's exceptions.)
    static let backgroundScripts: [(String, String)] = [
        ("notes create", NotesCapability.Script.create), ("notes append", NotesCapability.Script.append),
        ("notes set body", NotesCapability.Script.setBody), ("notes get body", NotesCapability.Script.getBody),
        ("notes move", NotesCapability.Script.move), ("notes create folder", NotesCapability.Script.createFolder),
        ("notes delete", NotesCapability.Script.delete), ("notes delete folder", NotesCapability.Script.deleteFolder),
        ("notes folders", NotesScriptReader.Script.folders), ("notes search", NotesScriptReader.Script.search),
        ("notes read", NotesScriptReader.Script.read), ("messages send", MessagesCapability.Script.send),
        ("mail content", MailCodes.Script.content), ("mail archive", MailCodes.Script.archive),
    ]

    @Test func backgroundScriptsNeverBringAnAppForward() {
        let words = ["activate", "system events", "keystroke", "clipboard", "reopen", "frontmost", "key code"]
        for (name, script) in Self.backgroundScripts {
            let low = script.lowercased()
            for w in words { #expect(!low.contains(w), "\(name) contains \(w)") }
        }
    }

    /// The background capabilities' code has nothing that drives a window, the pointer, the
    /// keyboard, or the clipboard, and opens apps only without bringing them forward.
    @Test func backgroundCapabilitiesHaveNoWindowCode() throws {
        let folders = ["Notes", "Calendar", "Contacts", "Reminders", "WhatsApp", "Files", "Location", "Mail"]
        let banned = [
            "System Events", "keystroke", "NSPasteboard", "activates = true", ".activate(", "CGEvent",
            "AXUIElementPerformAction", "AXUIElementSetAttributeValue", "set frontmost", "the clipboard",
        ]
        let files = try Self.sources(in: folders)
        #expect(files.count >= 8)
        for (file, text) in files {
            for b in banned { #expect(!text.contains(b), "\(file) contains \(b)") }
        }
    }
}

/// Calendar events in memory (FakeEvents) whose update also applies the repeat it is given, as
/// EventKit does.
final class RepeatingEventsD: EventsBackend, @unchecked Sendable {
    let inner = FakeEvents()

    func allowed(_ kind: EventsKind) -> Bool { inner.allowed(kind) }
    func calendars(_ kind: EventsKind) throws -> [CalendarInfo] { try inner.calendars(kind) }
    func events(from: Date, to: Date, calendars: [String]?) throws -> [EventInfo] {
        try inner.events(from: from, to: to, calendars: calendars)
    }
    func event(id: String) throws -> EventInfo { try inner.event(id: id) }
    func createEvent(_ draft: EventDraft) throws -> EventInfo { try inner.createEvent(draft) }
    func updateEvent(id: String, _ draft: EventDraft, future: Bool) throws -> EventInfo {
        var e = try inner.updateEvent(id: id, draft, future: future)
        switch draft.repeats {
        case .set(let r): e.repeats = r
        case .clear: e.repeats = nil
        case .keep: break
        }
        if let i = inner.stored.firstIndex(where: { $0.identifier == e.identifier }) { inner.stored[i] = e }
        return e
    }
    func deleteEvent(id: String, future: Bool) throws { try inner.deleteEvent(id: id, future: future) }
    func respond(id: String, _ answer: InvitationAnswer, comment: String?, future: Bool) throws -> EventInfo {
        try inner.respond(id: id, answer, comment: comment, future: future)
    }
    func reminders(completed: Bool, from: Date?, to: Date?, lists: [String]?) async throws -> [ReminderInfo] {
        try await inner.reminders(completed: completed, from: from, to: to, lists: lists)
    }
    func reminder(id: String) throws -> ReminderInfo { try inner.reminder(id: id) }
    func createReminder(_ draft: ReminderDraft) throws -> ReminderInfo { try inner.createReminder(draft) }
    func updateReminder(id: String, _ draft: ReminderDraft) throws -> ReminderInfo {
        try inner.updateReminder(id: id, draft)
    }
    func deleteReminder(id: String) throws { try inner.deleteReminder(id: id) }
    func moveReminders(_ ids: [String], list: String) throws -> [ReminderInfo] {
        try inner.moveReminders(ids, list: list)
    }
    func createList(title: String) throws -> CalendarInfo { try inner.createList(title: title) }
    func deleteList(id: String) throws { try inner.deleteList(id: id) }
}
