import EventKit
import Foundation
import Testing

@testable import Latchkey

/// Calendars and reminders in memory; the Owner's real ones are never touched.
final class FakeEvents: EventsBackend, @unchecked Sendable {
    var access = true
    var calendarList = [
        CalendarInfo(id: "C-HOME", title: "Home", account: "iCloud", writable: true, isDefault: true),
        CalendarInfo(id: "C-WORK", title: "Work", account: "Google", writable: true, isDefault: false),
        CalendarInfo(id: "C-HOL", title: "US Holidays", account: "Subscribed", writable: false, isDefault: false),
    ]
    var lists = [
        CalendarInfo(id: "L-TODO", title: "Reminders", account: "iCloud", writable: true, isDefault: true),
        CalendarInfo(id: "L-SHOP", title: "Groceries", account: "iCloud", writable: true, isDefault: false),
    ]
    var stored: [EventInfo] = []
    var reminderList: [ReminderInfo] = []
    var lastDraft: EventDraft?
    var lastReminderDraft: ReminderDraft?
    var lastFuture: Bool?
    var deleted: [String] = []

    func allowed(_ kind: EventsKind) -> Bool { access }
    func calendars(_ kind: EventsKind) throws -> [CalendarInfo] { kind == .events ? calendarList : lists }

    func events(from: Date, to: Date, calendars: [String]?) throws -> [EventInfo] {
        stored.filter { $0.end > from && $0.start < to && (calendars?.contains($0.calendarID) ?? true) }
            .sorted { $0.start < $1.start }
    }

    func event(id: String) throws -> EventInfo {
        guard let e = stored.first(where: { $0.id == id || $0.identifier == id }) else {
            throw EventsFailure.notFound(id)
        }
        return e
    }

    func createEvent(_ draft: EventDraft) throws -> EventInfo {
        lastDraft = draft
        let cal = try draft.calendar.map { try resolveCalendar($0, .events) } ?? calendarList[0]
        let e = EventInfo(
            identifier: "E\(stored.count + 1)", title: draft.title ?? "", start: draft.start!, end: draft.end!,
            allDay: draft.allDay ?? false, calendar: cal.title, calendarID: cal.id, location: draft.location.value,
            notes: draft.notes.value, alarms: draft.alarms.value ?? [], repeats: draft.repeats.value)
        stored.append(e)
        return e
    }

    func updateEvent(id: String, _ draft: EventDraft, future: Bool) throws -> EventInfo {
        lastDraft = draft
        lastFuture = future
        var e = try event(id: id)
        if let t = draft.title { e.title = t }
        if let s = draft.start {
            let length = e.end.timeIntervalSince(e.start)
            e.start = s
            e.end = draft.end ?? s.addingTimeInterval(length)
        } else if let end = draft.end {
            e.end = end
        }
        if let l = draft.location.value { e.location = l } else if draft.location == .clear { e.location = nil }
        stored[stored.firstIndex { $0.identifier == e.identifier }!] = e
        return e
    }

    func deleteEvent(id: String, future: Bool) throws {
        lastFuture = future
        let e = try event(id: id)
        deleted.append(e.id)
        stored.removeAll { $0.identifier == e.identifier }
    }

    func reminders(completed: Bool, from: Date?, to: Date?, lists: [String]?) async throws -> [ReminderInfo] {
        reminderList.filter { r in
            r.completed == completed && (lists?.contains(r.listID) ?? true)
                && (!completed
                    || ((from.map { r.completedAt! >= $0 } ?? true) && (to.map { r.completedAt! <= $0 } ?? true)))
        }
    }

    func reminder(id: String) throws -> ReminderInfo {
        guard let r = reminderList.first(where: { $0.id == id }) else { throw EventsFailure.notFound(id) }
        return r
    }

    func createReminder(_ draft: ReminderDraft) throws -> ReminderInfo {
        lastReminderDraft = draft
        let list = try draft.list.map { try resolveCalendar($0, .reminders) } ?? lists[0]
        let r = ReminderInfo(
            id: "R\(reminderList.count + 1)", title: draft.title ?? "", notes: draft.notes.value, list: list.title,
            listID: list.id, due: draft.due.value?.date, dueHasTime: draft.due.value.map { !$0.dateOnly } ?? false,
            priority: draft.priority ?? 0)
        reminderList.append(r)
        return r
    }

    func updateReminder(id: String, _ draft: ReminderDraft) throws -> ReminderInfo {
        lastReminderDraft = draft
        var r = try reminder(id: id)
        if let t = draft.title { r.title = t }
        if let c = draft.completed {
            r.completed = c
            r.completedAt = c ? Date() : nil
        }
        reminderList[reminderList.firstIndex { $0.id == id }!] = r
        return r
    }

    func deleteReminder(id: String) throws {
        deleted.append(id)
        reminderList.removeAll { $0.id == id }
    }

    func createList(title: String) throws -> CalendarInfo {
        let c = CalendarInfo(id: "L-\(title)", title: title, account: "iCloud", writable: true, isDefault: false)
        lists.append(c)
        return c
    }

    func deleteList(id: String) throws {
        guard lists.contains(where: { $0.id == id }) else { throw EventsFailure.notFound(id) }
        deleted.append(id)
        lists.removeAll { $0.id == id }
        reminderList.removeAll { $0.listID == id }
    }
}

@Suite struct CalendarDatesTests {
    static let la = TimeZone(identifier: "America/Los_Angeles")!

    @Test func readsDaysTimesAndOffsets() throws {
        let day = try CalendarDates.parse("2026-10-27", zone: Self.la)
        #expect(day.dateOnly)
        #expect(day.date == Date(timeIntervalSince1970: 1_793_084_400))  // 2026-10-27 00:00 PDT
        let local = try CalendarDates.parse("2026-10-27T15:30", zone: Self.la)
        #expect(!local.dateOnly)
        #expect(local.date == Date(timeIntervalSince1970: 1_793_140_200))
        #expect(try CalendarDates.parse("2026-10-27T22:30:00Z", zone: Self.la).date == local.date)
        #expect(try CalendarDates.parse("2026-10-28T00:30+02:00", zone: Self.la).date == local.date)
        #expect(try CalendarDates.parse("2026-10-27 15:30", zone: Self.la).date == local.date)
    }

    @Test func refusesWhatIsNotADate() {
        for bad in ["tomorrow", "2026-02-30", "2026-13-01", "2026-10-27T25:00", "27.10.2026", "2026-10-27T10:00+99:00"]
        {
            #expect(throws: ArgumentError.self, "\(bad)") { try CalendarDates.parse(bad, zone: Self.la) }
        }
    }

    @Test func formatsInTheMacZone() throws {
        let s = try CalendarDates.parse("2026-10-27T15:00", zone: Self.la).date
        let e = try CalendarDates.parse("2026-10-27T16:30", zone: Self.la).date
        #expect(CalendarDates.span(s, e, allDay: false, zone: Self.la) == "Tue 2026-10-27 15:00–16:30")
        let late = try CalendarDates.parse("2026-10-28T01:00", zone: Self.la).date
        #expect(
            CalendarDates.span(s, late, allDay: false, zone: Self.la) == "Tue 2026-10-27 15:00 – Wed 2026-10-28 01:00")
        let day = try CalendarDates.parse("2026-10-27", zone: Self.la).date
        let dayEnd = day.addingTimeInterval(86_399)  // EventKit ends an all-day event at 23:59:59
        #expect(CalendarDates.span(day, dayEnd, allDay: true, zone: Self.la) == "Tue 2026-10-27 (all day)")
        #expect(
            CalendarDates.span(day, dayEnd.addingTimeInterval(2 * 86_400), allDay: true, zone: Self.la)
                == "Tue 2026-10-27 – Thu 2026-10-29 (all day)")
        #expect(
            CalendarDates.zoneLine(Self.la, at: s)
                == "Times are in the Mac's time zone, America/Los_Angeles (UTC-07:00).")
    }

    @Test func findsFreeTimeInsideDayHours() throws {
        let p = { try CalendarDates.parse($0, zone: Self.la).date }
        let busy = [
            DateInterval(start: try p("2026-10-27T09:00"), end: try p("2026-10-27T10:00")),
            DateInterval(start: try p("2026-10-27T09:30"), end: try p("2026-10-27T11:00")),  // overlaps
            DateInterval(start: try p("2026-10-27T11:10"), end: try p("2026-10-27T12:00")),  // leaves 10 min
        ]
        let free = CalendarDates.freeTimes(
            busy: busy, from: try p("2026-10-27"), to: try p("2026-10-28"), minutes: 30, hours: (8 * 60, 18 * 60),
            zone: Self.la)
        #expect(
            free == [
                DateInterval(start: try p("2026-10-27T08:00"), end: try p("2026-10-27T09:00")),
                DateInterval(start: try p("2026-10-27T12:00"), end: try p("2026-10-27T18:00")),
            ])
        #expect(try CalendarDates.hours(nil) == (480, 1200))
        #expect(try CalendarDates.hours("9:00-17:30") == (540, 1050))
        #expect(throws: ArgumentError.self) { try CalendarDates.hours("17:00-09:00") }
    }

    @Test func eventIDsNameOneOccurrence() {
        let start = Date(timeIntervalSince1970: 1_761_604_200)
        let id = EventID.make("ABC:123@x", start: start)
        #expect(id == "ABC:123@x@1761604200")
        #expect(EventID.split(id) == ("ABC:123@x", start))
        #expect(EventID.split("PLAIN").start == nil)
    }

    @Test func buildsRepeatRules() {
        let r = EventKitBackend.rule(Repeat(frequency: "weekly", interval: 2, count: 5))
        #expect(r.frequency == .weekly && r.interval == 2 && r.recurrenceEnd?.occurrenceCount == 5)
        #expect(EventKitBackend.repeats([r]) == Repeat(frequency: "weekly", interval: 2, count: 5))
        #expect(Repeat(frequency: "daily").describe() == "every day")
    }
}

@Suite struct CalendarToolTests {
    static let la = CalendarDatesTests.la
    let fake = FakeEvents()

    func tool(_ name: String) throws -> ToolEntry {
        let all =
            CalendarCapability.readTools(backend: fake, zone: { Self.la })
            + CalendarCapability.writeTools(backend: fake, zone: { Self.la })
        return try #require(all.first { $0.tool.name == name })
    }

    func text(_ r: ToolResult) -> String {
        guard case .array(let items) = r.content else { return "" }
        return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    func date(_ s: String) throws -> Date { try CalendarDates.parse(s, zone: Self.la).date }

    func addEvent(_ title: String, _ start: String, _ end: String, own: Bool = true, calendar: String = "C-HOME") throws
    {
        fake.stored.append(
            EventInfo(
                identifier: "X\(fake.stored.count)", title: title, start: try date(start), end: try date(end),
                allDay: false, calendar: calendar == "C-HOME" ? "Home" : "Work", calendarID: calendar,
                organizer: own ? nil : "Sarah", ownEvent: own))
    }

    @Test func findListsEventsInARangeWithTheirZone() async throws {
        try addEvent("Dentist", "2026-10-27T15:00", "2026-10-27T16:00")
        try addEvent("Standup", "2026-10-28T09:00", "2026-10-28T09:15", calendar: "C-WORK")
        let r = try await tool("calendar_find").handler(
            .object(["from": .string("2026-10-27"), "to": .string("2026-10-27")]))
        let t = text(r)
        #expect(!r.isError, "\(t)")
        #expect(t.contains("America/Los_Angeles"))
        #expect(t.contains("Tue 2026-10-27 15:00–16:00  Dentist [Home]"))
        #expect(!t.contains("Standup"))  // a day as `to` means through its end, not past it
        let work = text(
            try await tool("calendar_find").handler(
                .object(["calendar": .string("work"), "from": .string("2026-10-27")])))
        #expect(work.contains("Standup") && !work.contains("Dentist"))
    }

    @Test func findWithNothingListsCalendarsToo() async throws {
        let t = text(try await tool("calendar_find").handler(.object([:])))
        #expect(t.contains("Home (iCloud; can be changed; default; id C-HOME)"))
        #expect(t.contains("US Holidays (Subscribed; read-only"))
    }

    @Test func findSearchesAndMarksOthersText() async throws {
        try addEvent("Lunch with Sarah", "2026-10-27T12:00", "2026-10-27T13:00", own: false)
        let t = text(
            try await tool("calendar_find").handler(
                .object(["query": .string("lunch"), "from": .string("2026-10-01")])))
        #expect(t.contains("«Lunch with Sarah»"))
        #expect(t.contains(MessagesCapability.marking))
    }

    @Test func freeTimeSkipsFreeAndAllDayEvents() async throws {
        try addEvent("Meeting", "2026-10-27T09:00", "2026-10-27T17:00")
        fake.stored.append(
            EventInfo(
                identifier: "AD", title: "Holiday", start: try date("2026-10-27"), end: try date("2026-10-27T23:59"),
                allDay: true, calendar: "Home", calendarID: "C-HOME"))
        let t = text(
            try await tool("calendar_find").handler(
                .object([
                    "free": .bool(true), "from": .string("2026-10-27"), "to": .string("2026-10-27"),
                    "minutes": .number(60),
                ])))
        #expect(t.contains("Tue 2026-10-27 08:00–09:00 (1 h)"))
        #expect(t.contains("Tue 2026-10-27 17:00–20:00 (3 h)"))
    }

    @Test func createsTimedAndAllDayEvents() async throws {
        let r = try await tool("calendar_change").handler(
            .object([
                "action": .string("create"), "title": .string("Dentist"), "start": .string("2026-10-27T15:00"),
                "calendar": .string("Work"), "alarms": .array([.number(10), .number(60)]),
                "location": .string("Main St"),
            ]))
        #expect(!r.isError, "\(text(r))")
        #expect(r.activity == "Claude added “Dentist” to Work")
        #expect(fake.lastDraft?.end == (try date("2026-10-27T16:00")))  // an hour by default
        #expect(fake.lastDraft?.alarms == .set([10, 60]))
        let allDay = try await tool("calendar_change").handler(
            .object([
                "action": .string("create"), "title": .string("Trip"), "start": .string("2026-11-02"),
                "end": .string("2026-11-04"),
            ]))
        #expect(!allDay.isError, "\(text(allDay))")
        #expect(fake.lastDraft?.allDay == true)
        let repeating = try await tool("calendar_change").handler(
            .object([
                "action": .string("create"), "title": .string("Yoga"), "start": .string("2026-10-27T07:00"),
                "repeat": .string("weekly"), "repeat_count": .number(10),
            ]))
        #expect(!repeating.isError)
        #expect(fake.lastDraft?.repeats == .set(Repeat(frequency: "weekly", interval: 1, count: 10)))
    }

    @Test func createRefusesBadInput() async throws {
        let change = try tool("calendar_change")
        let noTitle = await change.handler(
            .object(["action": .string("create"), "start": .string("2026-10-27T10:00")]))
        #expect(noTitle.isError)
        let backwards = await change.handler(
            .object([
                "action": .string("create"), "title": .string("X"), "start": .string("2026-10-27T10:00"),
                "end": .string("2026-10-27T09:00"),
            ]))
        #expect(text(backwards).contains("end must be after the start"))
        let noCalendar = await change.handler(
            .object([
                "action": .string("create"), "title": .string("X"), "start": .string("2026-10-27T10:00"),
                "calendar": .string("Gym"),
            ]))
        #expect(text(noCalendar).contains("Home, Work, US Holidays"))
        let both = await change.handler(
            .object([
                "action": .string("create"), "title": .string("X"), "start": .string("2026-10-27T10:00"),
                "repeat": .string("daily"), "repeat_count": .number(3), "repeat_until": .string("2026-11-01"),
            ]))
        #expect(both.isError)
        #expect(text(await change.handler(.object(["action": .string("invite")]))).contains("create, update, delete"))
    }

    @Test func updateMovesKeepingLengthAndDeleteRemoves() async throws {
        try addEvent("Dentist", "2026-10-27T15:00", "2026-10-27T16:00")
        let id = fake.stored[0].id
        let moved = try await tool("calendar_change").handler(
            .object([
                "action": .string("update"), "id": .string(id), "start": .string("2026-10-28T10:00"),
                "span": .string("future"),
            ]))
        #expect(!moved.isError, "\(text(moved))")
        #expect(fake.stored[0].end == (try date("2026-10-28T11:00")))
        #expect(fake.lastFuture == true)
        let newID = fake.stored[0].id
        let gone = try await tool("calendar_change").handler(
            .object(["action": .string("delete"), "id": .string(newID)]))
        #expect(!gone.isError)
        #expect(gone.activity == "Claude deleted “Dentist” from Home")
        #expect(fake.stored.isEmpty)
    }

    @Test func refusesInvitationsAndReadOnlyCalendars() async throws {
        try addEvent("Board meeting", "2026-10-27T15:00", "2026-10-27T16:00", own: false)
        var holiday = EventInfo(
            identifier: "H", title: "Thanksgiving", start: try date("2026-11-26"), end: try date("2026-11-26T23:59"),
            allDay: true, calendar: "US Holidays", calendarID: "C-HOL")
        holiday.writable = false
        fake.stored.append(holiday)
        let change = try tool("calendar_change")
        let invite = await change.handler(.object(["action": .string("delete"), "id": .string(fake.stored[0].id)]))
        #expect(invite.isError && text(invite).contains("only the organizer"))
        let ro = await change.handler(
            .object(["action": .string("update"), "id": .string(holiday.id), "title": .string("X")]))
        #expect(ro.isError && text(ro).contains("read-only"))
        #expect(fake.stored.count == 2)
    }

    @Test func saysWhatToAllowWithoutAccess() async throws {
        fake.access = false
        let r = try await tool("calendar_find").handler(.object([:]))
        #expect(r.isError && text(r).contains("Settings → Permissions"))
    }
}

@Suite struct RemindersToolTests {
    let fake = FakeEvents()
    static let la = CalendarDatesTests.la

    func tool(_ name: String) throws -> ToolEntry {
        let all =
            RemindersCapability.readTools(backend: fake, zone: { Self.la })
            + RemindersCapability.writeTools(backend: fake, zone: { Self.la })
        return try #require(all.first { $0.tool.name == name })
    }

    func text(_ r: ToolResult) -> String {
        guard case .array(let items) = r.content else { return "" }
        return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    @Test func listsOpenRemindersDatedFirst() async throws {
        fake.reminderList = [
            ReminderInfo(id: "R1", title: "Call mom", list: "Reminders", listID: "L-TODO"),
            ReminderInfo(
                id: "R2", title: "Milk", list: "Groceries", listID: "L-SHOP",
                due: try CalendarDates.parse("2026-10-27", zone: Self.la).date, priority: 1),
            ReminderInfo(
                id: "R3", title: "Old", list: "Reminders", listID: "L-TODO", completed: true, completedAt: Date()),
        ]
        let t = text(try await tool("reminders_find").handler(.object([:])))
        #expect(t.contains("Groceries (iCloud; 1 open; id L-SHOP)"))
        #expect(t.contains("☐ Milk [Groceries] due Tue 2026-10-27"))
        #expect(t.contains("(high priority)"))
        #expect(t.range(of: "Milk")!.lowerBound < t.range(of: "Call mom")!.lowerBound)
        #expect(!t.contains("Old"))
        let done = text(try await tool("reminders_find").handler(.object(["completed": .bool(true)])))
        #expect(done.contains("☑ Old") && !done.contains("Milk"))
    }

    @Test func createsCompletesAndDeletes() async throws {
        let change = try tool("reminders_change")
        let made = await change.handler(
            .object([
                "action": .string("create"), "title": .string("Buy milk"), "list": .string("groceries"),
                "due": .string("2026-10-27T17:00"), "priority": .string("medium"),
            ]))
        #expect(!made.isError, "\(text(made))")
        #expect(made.activity == "Claude added the reminder “Buy milk” to Groceries")
        #expect(fake.lastReminderDraft?.priority == 5)
        #expect(fake.lastReminderDraft?.due.value?.dateOnly == false)
        let done = await change.handler(.object(["action": .string("complete"), "id": .string("R1")]))
        #expect(done.activity == "Claude completed “Buy milk”")
        #expect(fake.reminderList[0].completed)
        let list = await change.handler(.object(["action": .string("create_list"), "title": .string("Packing")]))
        #expect(!list.isError && fake.lists.contains { $0.title == "Packing" })
        let gone = await change.handler(.object(["action": .string("delete"), "id": .string("R1")]))
        #expect(!gone.isError && fake.reminderList.isEmpty)
        let bad = await change.handler(
            .object(["action": .string("create"), "title": .string("X"), "priority": .string("urgent")]))
        #expect(bad.isError)
    }

    @Test func deletesAListOnlyWithItsReminderCount() async throws {
        fake.reminderList = [
            ReminderInfo(id: "R1", title: "Milk", list: "Groceries", listID: "L-SHOP"),
            ReminderInfo(
                id: "R2", title: "Eggs", list: "Groceries", listID: "L-SHOP", completed: true, completedAt: Date()),
            ReminderInfo(id: "R3", title: "Call mom", list: "Reminders", listID: "L-TODO"),
        ]
        let shown = text(try await tool("reminders_find").handler(.object(["list": .string("groceries")])))
        #expect(shown.contains("Groceries holds 2 reminders (1 open, 1 completed)"), "\(shown)")
        let change = try tool("reminders_change")
        let noCount = await change.handler(.object(["action": .string("delete_list"), "list": .string("Groceries")]))
        #expect(noCount.isError && text(noCount).contains("reminder_count"))
        let wrong = await change.handler(
            .object(["action": .string("delete_list"), "list": .string("Groceries"), "reminder_count": .number(1)]))
        #expect(wrong.isError && text(wrong).contains("holds 2 reminders"), "\(text(wrong))")
        #expect(fake.lists.contains { $0.id == "L-SHOP" } && fake.reminderList.count == 3)
        let noList = await change.handler(.object(["action": .string("delete_list"), "reminder_count": .number(0)]))
        #expect(noList.isError)
        let gone = await change.handler(
            .object(["action": .string("delete_list"), "list": .string("L-SHOP"), "reminder_count": .number(2)]))
        #expect(!gone.isError, "\(text(gone))")
        #expect(gone.activity == "Claude deleted the reminder list “Groceries” and its 2 reminders")
        #expect(!fake.lists.contains { $0.id == "L-SHOP" })
        #expect(fake.reminderList.map(\.id) == ["R3"])
        fake.lists[0].writable = false
        let locked = await change.handler(
            .object(["action": .string("delete_list"), "list": .string("Reminders"), "reminder_count": .number(1)]))
        #expect(locked.isError && fake.lists.count == 1)
    }

    @Test func clearsADueDateWithEmptyText() throws {
        let d = try RemindersCapability.draft(.object(["due": .string("")]), zone: Self.la)
        #expect(d?.due == .clear)
        #expect(try RemindersCapability.draft(.object([:]), zone: Self.la) == nil)
    }
}
