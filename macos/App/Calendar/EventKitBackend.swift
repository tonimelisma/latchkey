import EventKit
import Foundation

/// The Owner's calendars and reminders through EventKit (spec 007 plan D2). EventKit's store
/// isn't thread-safe, so every use goes through one lock.
final class EventKitBackend: EventsBackend, @unchecked Sendable {
    static let shared = EventKitBackend()

    private let lock = NSLock()
    private var cachedStore: EKEventStore?

    /// Made on first use, after the Owner allowed access: a store made before that keeps seeing
    /// nothing.
    private var store: EKEventStore {
        if let s = cachedStore { return s }
        let s = EKEventStore()
        cachedStore = s
        return s
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func status(_ kind: EventsKind) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: kind == .events ? .event : .reminder)
    }

    func allowed(_ kind: EventsKind) -> Bool { Self.status(kind) == .fullAccess }

    /// Asks macOS once (setup only, FR-742); a new store is made afterwards.
    static func requestAccess(_ kind: EventsKind) async -> (granted: Bool, error: String?) {
        let s = EKEventStore()
        defer { shared.locked { shared.cachedStore = nil } }
        do {
            return (try await (kind == .events ? s.requestFullAccessToEvents() : s.requestFullAccessToReminders()), nil)
        } catch {
            return (false, "\(error)")
        }
    }

    private func check(_ kind: EventsKind) throws {
        guard allowed(kind) else { throw EventsFailure.noAccess(kind) }
    }

    // MARK: calendars

    func calendars(_ kind: EventsKind) throws -> [CalendarInfo] {
        try check(kind)
        return locked {
            let type: EKEntityType = kind == .events ? .event : .reminder
            let defaultID =
                (kind == .events ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders())?
                .calendarIdentifier
            return store.calendars(for: type).map {
                CalendarInfo(
                    id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                    writable: $0.allowsContentModifications, isDefault: $0.calendarIdentifier == defaultID)
            }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    private func ekCalendars(_ ids: [String]?, _ type: EKEntityType) -> [EKCalendar]? {
        ids.map { ids in store.calendars(for: type).filter { ids.contains($0.calendarIdentifier) } }
    }

    private func ekCalendar(_ nameOrID: String?, _ kind: EventsKind) throws -> EKCalendar? {
        guard let nameOrID else { return nil }
        let info = try resolveCalendar(nameOrID, kind)
        return locked { store.calendar(withIdentifier: info.id) }
    }

    // MARK: events

    func events(from: Date, to: Date, calendars: [String]?) throws -> [EventInfo] {
        try check(.events)
        return locked {
            let cals = ekCalendars(calendars, .event)
            if cals?.isEmpty == true { return [] }
            let p = store.predicateForEvents(withStart: from, end: to, calendars: cals)
            return store.events(matching: p).sorted { $0.startDate < $1.startDate }.map(Self.info)
        }
    }

    private func ekEvent(_ id: String) throws -> EKEvent {
        let (identifier, start) = EventID.split(id)
        let found: EKEvent? = locked {
            guard let start else { return store.event(withIdentifier: identifier) }
            let p = store.predicateForEvents(
                withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: nil)
            return store.events(matching: p).first {
                $0.eventIdentifier == identifier && abs($0.startDate.timeIntervalSince(start)) < 1
            }
        }
        guard let found else { throw EventsFailure.notFound(id) }
        return found
    }

    func event(id: String) throws -> EventInfo {
        try check(.events)
        return Self.info(try ekEvent(id))
    }

    func createEvent(_ draft: EventDraft) throws -> EventInfo {
        try check(.events)
        let calendar = try ekCalendar(draft.calendar, .events)
        return try locked {
            let e = EKEvent(eventStore: store)
            e.calendar = calendar ?? store.defaultCalendarForNewEvents
            guard e.calendar != nil else { throw EventsFailure.failed("This Mac has no calendar to add events to.") }
            try apply(draft, to: e)
            try save(e, span: .thisEvent)
            return Self.info(e)
        }
    }

    func updateEvent(id: String, _ draft: EventDraft, future: Bool) throws -> EventInfo {
        try check(.events)
        let e = try ekEvent(id)
        let calendar = try ekCalendar(draft.calendar, .events)
        return try locked {
            if let calendar { e.calendar = calendar }
            try apply(draft, to: e)
            try save(e, span: future ? .futureEvents : .thisEvent)
            return Self.info(e)
        }
    }

    func deleteEvent(id: String, future: Bool) throws {
        try check(.events)
        let e = try ekEvent(id)
        try locked {
            do { try store.remove(e, span: future ? .futureEvents : .thisEvent, commit: true) } catch {
                throw EventsFailure.failed(error.localizedDescription)
            }
        }
    }

    private func save(_ e: EKEvent, span: EKSpan) throws {
        do { try store.save(e, span: span, commit: true) } catch {
            store.reset()
            throw EventsFailure.failed(error.localizedDescription)
        }
    }

    private func apply(_ d: EventDraft, to e: EKEvent) throws {
        if let title = d.title { e.title = title }
        if let allDay = d.allDay { e.isAllDay = allDay }
        let length = (e.endDate ?? Date()).timeIntervalSince(e.startDate ?? Date())
        if let start = d.start {
            e.startDate = start
            // Moving the start keeps the length unless a new end is given.
            if d.end == nil { e.endDate = start.addingTimeInterval(max(length, 0)) }
        }
        if let end = d.end { e.endDate = end }
        switch d.location {
        case .keep: break
        case .clear: e.location = nil
        case .set(let s): e.location = s
        }
        switch d.notes {
        case .keep: break
        case .clear: e.notes = nil
        case .set(let s): e.notes = s
        }
        switch d.url {
        case .keep: break
        case .clear: e.url = nil
        case .set(let s): e.url = URL(string: s)
        }
        if case .set(let minutes) = d.alarms {
            e.alarms = minutes.map { EKAlarm(relativeOffset: -Double($0) * 60) }
        } else if d.alarms == .clear {
            e.alarms = nil
        }
        switch d.repeats {
        case .keep: break
        case .clear: e.recurrenceRules = nil
        case .set(let r): e.recurrenceRules = [Self.rule(r)]
        }
    }

    static func rule(_ r: Repeat) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency =
            switch r.frequency {
            case "weekly": .weekly
            case "monthly": .monthly
            case "yearly": .yearly
            default: .daily
            }
        let end = r.until.map { EKRecurrenceEnd(end: $0) } ?? r.count.map { EKRecurrenceEnd(occurrenceCount: $0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: r.interval, end: end)
    }

    static func repeats(_ rules: [EKRecurrenceRule]?) -> Repeat? {
        guard let r = rules?.first else { return nil }
        let name =
            switch r.frequency {
            case .daily: "daily"
            case .weekly: "weekly"
            case .monthly: "monthly"
            case .yearly: "yearly"
            @unknown default: "daily"
            }
        let count = r.recurrenceEnd?.occurrenceCount ?? 0
        return Repeat(
            frequency: name, interval: r.interval, until: r.recurrenceEnd?.endDate, count: count > 0 ? count : nil)
    }

    private static func status(_ s: EKParticipantStatus) -> String {
        switch s {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "not answered"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in process"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func info(_ e: EKEvent) -> EventInfo {
        let attendees = (e.attendees ?? []).map { p in
            Attendee(
                name: p.name ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                email: p.url.scheme == "mailto"
                    ? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    : nil,
                status: status(p.participantStatus), isOwner: p.isCurrentUser)
        }
        return EventInfo(
            identifier: e.eventIdentifier ?? e.calendarItemIdentifier, title: e.title ?? "(no title)",
            start: e.startDate, end: e.endDate, allDay: e.isAllDay, calendar: e.calendar?.title ?? "",
            calendarID: e.calendar?.calendarIdentifier ?? "", location: e.location?.nilIfEmpty,
            notes: e.notes?.nilIfEmpty, url: e.url?.absoluteString,
            alarms: (e.alarms ?? []).compactMap {
                $0.absoluteDate == nil ? Int((-$0.relativeOffset / 60).rounded()) : nil
            },
            repeats: repeats(e.recurrenceRules), attendees: attendees, organizer: e.organizer?.name,
            ownEvent: e.organizer == nil || e.organizer?.isCurrentUser == true || attendees.isEmpty,
            writable: e.calendar?.allowsContentModifications ?? false, markedFree: e.availability == .free,
            cancelled: e.status == .canceled)
    }

    // MARK: reminders

    func reminders(completed: Bool, from: Date?, to: Date?, lists: [String]?) async throws -> [ReminderInfo] {
        try check(.reminders)
        let (store, predicate): (EKEventStore, NSPredicate?) = locked {
            let cals = ekCalendars(lists, .reminder)
            if cals?.isEmpty == true { return (self.store, nil) }
            let p =
                completed
                ? self.store.predicateForCompletedReminders(
                    withCompletionDateStarting: from, ending: to, calendars: cals)
                : self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
            return (self.store, p)
        }
        guard let predicate else { return [] }
        let found: [ReminderInfo] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { list in
                done.resume(returning: (list ?? []).map(Self.info))
            }
        }
        return found
    }

    private func ekReminder(_ id: String) throws -> EKReminder {
        guard let r = locked({ store.calendarItem(withIdentifier: id) as? EKReminder }) else {
            throw EventsFailure.notFound(id)
        }
        return r
    }

    func reminder(id: String) throws -> ReminderInfo {
        try check(.reminders)
        return Self.info(try ekReminder(id))
    }

    func createReminder(_ draft: ReminderDraft) throws -> ReminderInfo {
        try check(.reminders)
        let list = try ekCalendar(draft.list, .reminders)
        return try locked {
            let r = EKReminder(eventStore: store)
            r.calendar = list ?? store.defaultCalendarForNewReminders()
            guard r.calendar != nil else { throw EventsFailure.failed("This Mac has no reminder list to add to.") }
            apply(draft, to: r)
            try save(r)
            return Self.info(r)
        }
    }

    func updateReminder(id: String, _ draft: ReminderDraft) throws -> ReminderInfo {
        try check(.reminders)
        let r = try ekReminder(id)
        let list = try ekCalendar(draft.list, .reminders)
        return try locked {
            if let list { r.calendar = list }
            apply(draft, to: r)
            try save(r)
            return Self.info(r)
        }
    }

    func moveReminders(_ ids: [String], list: String) throws -> [ReminderInfo] {
        try check(.reminders)
        let items = try ids.map(ekReminder)
        guard let cal = try ekCalendar(list, .reminders) else { throw EventsFailure.notFound(list) }
        return try locked {
            do {
                for r in items {
                    r.calendar = cal
                    try store.save(r, commit: false)
                }
                try store.commit()
            } catch {
                store.reset()
                throw EventsFailure.failed(error.localizedDescription)
            }
            return items.map(Self.info)
        }
    }

    func deleteReminder(id: String) throws {
        try check(.reminders)
        let r = try ekReminder(id)
        try locked {
            do { try store.remove(r, commit: true) } catch { throw EventsFailure.failed(error.localizedDescription) }
        }
    }

    func createList(title: String) throws -> CalendarInfo {
        try check(.reminders)
        return try locked {
            let c = EKCalendar(for: .reminder, eventStore: store)
            c.title = title
            guard let source = store.defaultCalendarForNewReminders()?.source else {
                throw EventsFailure.failed("This Mac has no account to add a reminder list to.")
            }
            c.source = source
            do { try store.saveCalendar(c, commit: true) } catch {
                store.reset()
                throw EventsFailure.failed(error.localizedDescription)
            }
            return CalendarInfo(
                id: c.calendarIdentifier, title: c.title, account: source.title, writable: true, isDefault: false,
                openCount: 0)
        }
    }

    func deleteList(id: String) throws {
        try check(.reminders)
        try locked {
            guard let c = store.calendar(withIdentifier: id), c.allowedEntityTypes.contains(.reminder) else {
                throw EventsFailure.notFound(id)
            }
            do { try store.removeCalendar(c, commit: true) } catch {
                store.reset()
                throw EventsFailure.failed(error.localizedDescription)
            }
        }
    }

    private func save(_ r: EKReminder) throws {
        do { try store.save(r, commit: true) } catch {
            store.reset()
            throw EventsFailure.failed(error.localizedDescription)
        }
    }

    private func apply(_ d: ReminderDraft, to r: EKReminder) {
        if let title = d.title { r.title = title }
        switch d.notes {
        case .keep: break
        case .clear: r.notes = nil
        case .set(let s): r.notes = s
        }
        switch d.url {
        case .keep: break
        case .clear: r.url = nil
        case .set(let s): r.url = URL(string: s)
        }
        if let p = d.priority { r.priority = p }
        if let done = d.completed { r.isCompleted = done }
        switch d.due {
        case .keep: break
        case .clear:
            r.dueDateComponents = nil
            r.alarms = nil
        case .set(let due):
            let units: Set<Calendar.Component> =
                due.dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            r.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
            // Like the Reminders app: a due time alerts at that time; a day has no alert.
            r.alarms = due.dateOnly ? nil : [EKAlarm(absoluteDate: due.date)]
        }
        switch d.repeats {
        case .keep: break
        case .clear: r.recurrenceRules = nil
        case .set(let rule): r.recurrenceRules = [Self.rule(rule)]
        }
    }

    private static func info(_ r: EKReminder) -> ReminderInfo {
        let due = r.dueDateComponents
        return ReminderInfo(
            id: r.calendarItemIdentifier, title: r.title ?? "(no title)", notes: r.notes?.nilIfEmpty,
            list: r.calendar?.title ?? "", listID: r.calendar?.calendarIdentifier ?? "",
            due: due.flatMap { Calendar.current.date(from: $0) }, dueHasTime: due?.hour != nil, priority: r.priority,
            completed: r.isCompleted, completedAt: r.completionDate, url: r.url?.absoluteString,
            repeats: repeats(r.recurrenceRules))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
