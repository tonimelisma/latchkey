import Foundation

/// Calendar and Reminders data as the tools use it (spec 007 plan D2). The app's backend is
/// EventKit (`EventKitBackend`); tests use one in memory and never touch the Owner's calendars.
enum EventsKind: Sendable { case events, reminders }

struct CalendarInfo: Sendable, Equatable {
    var id: String
    var title: String
    /// The account it belongs to: iCloud, Google, On My Mac, …
    var account: String
    var writable: Bool
    var isDefault: Bool
    /// For reminder lists: how many are open.
    var openCount: Int?
}

struct Repeat: Sendable, Equatable {
    static let frequencies = ["daily", "weekly", "monthly", "yearly"]
    var frequency: String
    var interval = 1
    var until: Date?
    var count: Int?

    /// "every 2 weeks until Tue 2027-01-05", "every day, 10 times".
    func describe(zone: TimeZone = .current) -> String {
        let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"][frequency] ?? frequency
        var s = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)s"
        if let until { s += " until \(CalendarDates.format(until, day: true, zone: zone))" }
        if let count { s += ", \(count) times" }
        return s
    }
}

/// What a change does to an optional field: leave it, clear it, or set it.
enum Change<Value: Sendable & Equatable>: Sendable, Equatable {
    case keep
    case clear
    case set(Value)

    var value: Value? { if case .set(let v) = self { v } else { nil } }
}

struct Attendee: Sendable, Equatable {
    var name: String
    var email: String?
    /// accepted, declined, tentative, pending, …
    var status: String
    var isOwner: Bool
}

struct EventInfo: Sendable, Equatable {
    var identifier: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendar: String
    var calendarID: String
    var location: String?
    var notes: String?
    var url: String?
    /// Minutes before the start.
    var alarms: [Int] = []
    var repeats: Repeat?
    var attendees: [Attendee] = []
    var organizer: String?
    /// The Owner organizes it, or nobody was invited: it's the Owner's own event.
    var ownEvent = true
    /// The calendar allows changes.
    var writable = true
    /// Marked "free" in its availability.
    var markedFree = false
    var cancelled = false

    var id: String { EventID.make(identifier, start: start) }

    var declined: Bool { attendees.contains { $0.isOwner && $0.status == "declined" } }

    /// Counts against free time (research.md "Free time").
    var busy: Bool { !allDay && !markedFree && !cancelled && !declined }
}

struct EventDraft: Sendable, Equatable {
    var title: String?
    var start: Date?
    var end: Date?
    var allDay: Bool?
    /// A calendar's id or name.
    var calendar: String?
    var location: Change<String> = .keep
    var notes: Change<String> = .keep
    var url: Change<String> = .keep
    var alarms: Change<[Int]> = .keep
    var repeats: Change<Repeat> = .keep
}

struct ReminderInfo: Sendable, Equatable {
    var id: String
    var title: String
    var notes: String?
    var list: String
    var listID: String
    var due: Date?
    /// The due date has a time (otherwise it's a day).
    var dueHasTime = false
    /// 0 none, 1 high, 5 medium, 9 low (Apple's values).
    var priority = 0
    var completed = false
    var completedAt: Date?
    var url: String?
    var repeats: Repeat?

    var priorityName: String? { Self.priorityNames[priority] }

    static let priorityNames = [1: "high", 5: "medium", 9: "low"]
    static let priorities = ["none": 0, "high": 1, "medium": 5, "low": 9]
}

struct ReminderDraft: Sendable, Equatable {
    var title: String?
    var notes: Change<String> = .keep
    /// A list's id or name.
    var list: String?
    var due: Change<CalendarDates.Parsed> = .keep
    var priority: Int?
    var url: Change<String> = .keep
    var completed: Bool?
    var repeats: Change<Repeat> = .keep
}

enum EventsFailure: Error, Equatable {
    case noAccess(EventsKind)
    case notFound(String)
    case noSuchCalendar(String, available: [String])
    case readOnlyCalendar(String)
    case failed(String)
}

protocol EventsBackend: Sendable {
    func allowed(_ kind: EventsKind) -> Bool
    func calendars(_ kind: EventsKind) throws -> [CalendarInfo]
    func events(from: Date, to: Date, calendars: [String]?) throws -> [EventInfo]
    func event(id: String) throws -> EventInfo
    func createEvent(_ draft: EventDraft) throws -> EventInfo
    func updateEvent(id: String, _ draft: EventDraft, future: Bool) throws -> EventInfo
    func deleteEvent(id: String, future: Bool) throws
    func reminders(completed: Bool, from: Date?, to: Date?, lists: [String]?) async throws -> [ReminderInfo]
    func reminder(id: String) throws -> ReminderInfo
    func createReminder(_ draft: ReminderDraft) throws -> ReminderInfo
    func updateReminder(id: String, _ draft: ReminderDraft) throws -> ReminderInfo
    func deleteReminder(id: String) throws
    /// Moves reminders to a list (name or id) in one save: a reminder with subtasks moves only
    /// together with them.
    func moveReminders(_ ids: [String], list: String) throws -> [ReminderInfo]
    func createList(title: String) throws -> CalendarInfo
    /// Deletes a reminder list and every reminder in it.
    func deleteList(id: String) throws
}

extension EventsBackend {
    /// The calendar a name or id names, among `kind`'s.
    func resolveCalendar(_ nameOrID: String, _ kind: EventsKind) throws -> CalendarInfo {
        let all = try calendars(kind)
        if let c = all.first(where: { $0.id == nameOrID }) { return c }
        let named = all.filter {
            $0.title.compare(nameOrID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard let c = named.first(where: \.writable) ?? named.first else {
            throw EventsFailure.noSuchCalendar(nameOrID, available: all.map(\.title))
        }
        return c
    }
}
