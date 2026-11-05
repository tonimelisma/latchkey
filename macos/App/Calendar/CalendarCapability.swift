import Foundation

/// The Owner's calendars (spec 007 US1): find and change, through EventKit (plan D2).
enum CalendarCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.calendar, title: "Calendar",
            summary: "See your calendars, find free time, and add, change, or delete events",
            readTools: readTools(backend: EventKitBackend.shared, zone: { .current }),
            writeTools: writeTools(backend: EventKitBackend.shared, zone: { .current }))
    }

    typealias Zone = @Sendable () -> TimeZone

    static let noAccess = """
        Latchkey can't see the calendars: macOS hasn't allowed it. The Mac's owner can allow \
        Calendars in Latchkey's Settings → Permissions.
        """

    /// The most events one answer lists (research.md "Search sizes").
    static let maxEvents = 200

    static func readTools(backend: any EventsBackend, zone: @escaping Zone) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "calendar_find", title: "Find Calendar Events",
                    description: """
                        Lists and searches events in the Mac's calendars (iCloud, Google, Exchange, and others), \
                        repeating events as their single occurrences, with each event's id. With id: that event in \
                        full (notes, attendees, alarms, repeats). With free: true, the free times of at least \
                        minutes (default 30) in the range, within hours (default 08:00-20:00), across all \
                        calendars. With nothing: the calendars and the next 7 days. Dates: \(CalendarDates.accepted); \
                        from defaults to the start of today, to to 7 days later (30 with a query).
                        """,
                    input: [
                        "id": .stringParam("An event's id, to read it in full"),
                        "query": .stringParam("Words in the title, location, or notes"),
                        "from": .stringParam("Start of the range"),
                        "to": .stringParam("End of the range"),
                        "calendar": .stringParam("Only this calendar (name or id)"),
                        "free": .boolParam("List free times instead of events"),
                        "minutes": .integerParam("For free: the shortest free time to list (default 30)"),
                        "hours": .stringParam("For free: the part of each day to look in (default 08:00-20:00)"),
                        "limit": .integerParam("At most this many events (default 50, up to 200)"),
                    ], readOnly: true, deadlineMS: 15_000),
                handler: { args in await run(.events) { try await find(args, backend, zone()) } })
        ]
    }

    static let changeActions = ["create", "update", "delete", "respond"]
    static let answers = ["accept", "maybe", "decline"]

    static func writeTools(backend: any EventsBackend, zone: @escaping Zone) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "calendar_change", title: "Change Calendar Events",
                    description: """
                        Creates, changes, or deletes an event in the Mac's calendars, invites people, and answers \
                        invitations. action: create (title, start, and end, or all-day dates; calendar, location, \
                        notes, url, alarms, repeat, invite are optional), update (id and only the fields to change; \
                        moving start keeps the length; invite and uninvite add or remove people by email), delete \
                        (id; it can't be undone), respond (id and answer: accept, maybe, or decline an invitation; \
                        comment is optional; the organizer is told). invite sends invitations from the calendar's \
                        account (iCloud, Google, Exchange). An invitation from someone else can be changed too, but \
                        only the Owner's copy changes unless the organizer lets guests change it. For a repeating \
                        event, span: this (default) changes the one occurrence, future that one and all later ones. \
                        Dates: \(CalendarDates.accepted); a date without a time makes an all-day event. An empty \
                        text clears a field. Events in read-only calendars (holidays, subscriptions) can't be changed.
                        """,
                    input: [
                        "action": .enumParam(changeActions, "What to do"),
                        "id": .stringParam("The event's id, from calendar_find (for update and delete)"),
                        "title": .stringParam("The event's title"),
                        "start": .stringParam("When it starts"),
                        "end": .stringParam(
                            "When it ends (default an hour after the start; for all-day, the last day)"),
                        "all_day": .boolParam("An all-day event"),
                        "calendar": .stringParam("The calendar (name or id; default the Mac's default calendar)"),
                        "location": .stringParam("Where"),
                        "notes": .stringParam("Notes"),
                        "url": .stringParam("A link"),
                        "alarms": .object([
                            "type": .string("array"), "items": .object(["type": .string("integer")]),
                            "description": .string("Alerts, in minutes before the start, like [10, 60]; [] for none"),
                        ]),
                        "repeat": .enumParam(["none"] + Repeat.frequencies, "How it repeats; none stops repeating"),
                        "repeat_every": .integerParam("Repeat every this many days, weeks, … (default 1)"),
                        "repeat_until": .stringParam("Last day it repeats"),
                        "repeat_count": .integerParam("Or: how many times in all"),
                        "span": .enumParam(
                            ["this", "future"], "For a repeating event: this occurrence or this and later ones"),
                        "invite": .object([
                            "type": .string("array"), "items": .object(["type": .string("string")]),
                            "description": .string("Email addresses to invite (create and update)"),
                        ]),
                        "uninvite": .object([
                            "type": .string("array"), "items": .object(["type": .string("string")]),
                            "description": .string("Email addresses to take off the event (update)"),
                        ]),
                        "answer": .enumParam(answers, "For respond: the Owner's answer to the invitation"),
                        "comment": .stringParam("For respond: a note to the organizer"),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 15_000),
                handler: { args in await run(.events) { try change(args, backend, zone()) } })
        ]
    }

    // MARK: find

    static func find(_ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone) async throws -> ToolResult {
        guard backend.allowed(.events) else { throw EventsFailure.noAccess(.events) }
        if let id = args["id"]?.stringValue, !id.isEmpty {
            let e = try backend.event(id: id)
            return .text(CalendarDates.zoneLine(zone, at: e.start) + "\n\n" + describe(e, zone: zone))
        }
        let cal = CalendarDates.calendar(zone)
        let from = try CalendarDates.argument(args, "from", zone: zone)?.date ?? cal.startOfDay(for: Date())
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let defaultDays = query.isEmpty ? 7 : 30
        var to =
            try CalendarDates.argument(args, "to", zone: zone).map {
                // A day as the end means the whole of that day.
                $0.dateOnly ? cal.date(byAdding: .day, value: 1, to: $0.date)! : $0.date
            } ?? cal.date(byAdding: .day, value: defaultDays, to: from)!
        guard to > from else { throw ArgumentError(message: "to must be after from.") }
        guard to.timeIntervalSince(from) <= 4 * 366 * 86_400 else {
            throw ArgumentError(message: "The range can be at most 4 years.")
        }
        to = min(to, from.addingTimeInterval(4 * 366 * 86_400))
        var calendars: [String]?
        if let name = args["calendar"]?.stringValue, !name.isEmpty {
            calendars = [try backend.resolveCalendar(name, .events).id]
        }
        var lines = [CalendarDates.zoneLine(zone, at: from)]
        let all = try backend.events(from: from, to: to, calendars: calendars)
        let range = "\(CalendarDates.format(from, zone: zone)) – \(CalendarDates.format(to, zone: zone))"

        if args["free"]?.boolValue == true {
            let minutes = try args.integer("minutes", in: 1...(24 * 60)) ?? 30
            let hours = try CalendarDates.hours(args["hours"]?.stringValue)
            let free = CalendarDates.freeTimes(
                busy: all.filter(\.busy).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                from: from, to: to, minutes: minutes, hours: hours, zone: zone)
            lines.append(
                "Free times of \(minutes) minutes or more, \(range), within \(args["hours"]?.stringValue ?? "08:00-20:00"):"
            )
            lines +=
                free.isEmpty
                ? ["None."]
                : free.map {
                    "- \(CalendarDates.span($0.start, $0.end, allDay: false, zone: zone)) (\(duration($0.duration)))"
                }
            return .text(lines.joined(separator: "\n"))
        }

        if !args.hasAny("from", "to", "query", "calendar") {
            lines.append("Calendars:")
            lines += try backend.calendars(.events).map { c in
                "- \(c.title) (\(c.account); \(c.writable ? "can be changed" : "read-only")\(c.isDefault ? "; default" : ""); id \(c.id))"
            }
            lines.append("")
        }
        let limit = min(try args.integer("limit", in: 1...Int.max) ?? 50, maxEvents)
        let matching =
            query.isEmpty
            ? all
            : all.filter { e in
                [e.title, e.location ?? "", e.notes ?? ""].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        lines.append("Events\(query.isEmpty ? "" : " matching “\(query)”"), \(range):")
        if matching.isEmpty { lines.append("None.") }
        lines += matching.prefix(limit).map { "- " + line($0, zone: zone) }
        if matching.count > limit {
            lines.append("… and \(matching.count - limit) more; narrow the range or raise limit (up to \(maxEvents)).")
        }
        if matching.prefix(limit).contains(where: { !$0.ownEvent }) {
            lines.append("\n" + MessagesCapability.marking)
        }
        return .text(lines.joined(separator: "\n"))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// An event's title; invitations from others are their words (FR-746).
    private static func title(_ e: EventInfo) -> String { e.ownEvent ? e.title : MessagesCapability.quote(e.title) }

    static func line(_ e: EventInfo, zone: TimeZone) -> String {
        var s = "\(CalendarDates.span(e.start, e.end, allDay: e.allDay, zone: zone))  \(title(e)) [\(e.calendar)]"
        if let l = e.location { s += " at \(e.ownEvent ? l : MessagesCapability.quote(l))" }
        if e.repeats != nil { s += " (repeats)" }
        if e.cancelled { s += " (cancelled)" }
        if e.declined { s += " (declined)" }
        return s + " (id \(e.id))"
    }

    static func describe(_ e: EventInfo, zone: TimeZone) -> String {
        var lines = [
            "Title: \(title(e))", "When: \(CalendarDates.span(e.start, e.end, allDay: e.allDay, zone: zone))",
            "Calendar: \(e.calendar) (\(!e.writable ? "read-only" : e.changesReachOthers ? "can be changed" : "an invitation; changes reach only your copy"))",
        ]
        if !e.ownEvent, let me = e.attendees.first(where: \.isOwner) {
            lines.append(
                "Your answer: \(me.status)\(e.canRespond && e.writable ? " (calendar_change respond answers it)" : "")")
        }
        let q: (String) -> String = { e.ownEvent ? $0 : MessagesCapability.quote($0) }
        if let l = e.location { lines.append("Location: \(q(l))") }
        if let r = e.repeats { lines.append("Repeats: \(r.describe(zone: zone))") }
        if !e.alarms.isEmpty {
            lines.append("Alerts: \(e.alarms.map(String.init).joined(separator: ", ")) minutes before")
        }
        if let o = e.organizer { lines.append("Organizer: \(MessagesCapability.quote(o))") }
        if !e.attendees.isEmpty {
            lines.append(
                "Attendees: "
                    + e.attendees.map { a in
                        (a.isOwner ? "the Owner" : MessagesCapability.quote(a.name))
                            + (a.email.map { " <\($0)>" } ?? "")
                            + " (\(a.status))"
                    }.joined(separator: ", "))
        }
        if e.cancelled { lines.append("Status: cancelled") }
        if e.markedFree { lines.append("Shows as: free") }
        if let u = e.url { lines.append("Link: \(u)") }
        if let n = e.notes { lines.append("Notes:\n\(q(n))") }
        lines.append("id: \(e.id)")
        if !e.ownEvent || !e.attendees.isEmpty || e.organizer != nil { lines.append("\n" + MessagesCapability.marking) }
        return lines.joined(separator: "\n")
    }

    // MARK: change

    static func change(_ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone) throws -> ToolResult {
        guard backend.allowed(.events) else { throw EventsFailure.noAccess(.events) }
        let action = args["action"]?.stringValue
        let future = try span(args)
        switch action {
        case "create":
            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                throw ArgumentError(message: "Give the event's title.")
            }
            guard var d = try draft(args, zone: zone), d.start != nil else {
                throw ArgumentError(message: "Give the event's start (\(CalendarDates.accepted)).")
            }
            d.title = title
            guard d.uninvite.isEmpty else { throw ArgumentError(message: "uninvite works only with update.") }
            let e = try backend.createEvent(d)
            var r = ToolResult.text(
                "Added “\(e.title)” to \(e.calendar): \(CalendarDates.span(e.start, e.end, allDay: e.allDay, zone: zone))\(Self.repeating(e, zone: zone)). id \(e.id)\n"
                    + Self.invited(d) + CalendarDates.zoneLine(zone, at: e.start))
            r.activity = "Claude added “\(e.title)” to \(e.calendar)"
            r.made = "the event “\(e.title)” in \(e.calendar)"
            return r
        case "update":
            let old = try changeable(args, backend)
            guard var d = try draft(args, zone: zone, existing: old) else {
                throw ArgumentError(message: "Give at least one field to change.")
            }
            if let t = args["title"]?.stringValue, !t.isEmpty { d.title = t }
            try checkPeople(d, old)
            let e = try backend.updateEvent(id: old.id, d, future: future)
            let copy =
                old.changesReachOthers
                ? ""
                : "This changed your copy only: the organizer and other guests keep theirs, and the organizer's next update may replace it.\n"
            var r = ToolResult.text(
                "Changed \(title(e))\(future && old.repeats != nil ? " and its later occurrences" : ""): "
                    + "\(CalendarDates.span(e.start, e.end, allDay: e.allDay, zone: zone))\(Self.repeating(e, zone: zone, was: old)) [\(e.calendar)]. id \(e.id)\n"
                    + Self.invited(d) + copy + CalendarDates.zoneLine(zone, at: e.start))
            r.activity = "Claude changed “\(e.title)” in \(e.calendar)"
            return r
        case "delete":
            let old = try changeable(args, backend)
            try backend.deleteEvent(id: old.id, future: future)
            let which = old.repeats == nil ? "" : future ? " and its later occurrences" : " (this occurrence)"
            let note =
                old.ownEvent
                ? "" : " It was an invitation: to tell the organizer you won't come, respond decline instead."
            var r = ToolResult.text(
                "Deleted \(title(old))\(which), \(CalendarDates.span(old.start, old.end, allDay: old.allDay, zone: zone)), from \(old.calendar).\(note)"
            )
            r.activity = "Claude deleted “\(old.title)” from \(old.calendar)"
            return r
        case "respond":
            let old = try changeable(args, backend)
            guard let word = args["answer"]?.stringValue, let answer = InvitationAnswer(word: word) else {
                throw ArgumentError(message: "Give answer: accept, maybe, or decline.")
            }
            guard !old.ownEvent, old.attendees.contains(where: \.isOwner) else {
                throw ArgumentError(
                    message: "“\(old.title)” isn't an invitation to the Owner from someone else, so there's nothing to answer.")
            }
            guard old.canRespond else {
                throw ArgumentError(
                    message:
                        "\(title(old)) can't be answered on this Mac (its account doesn't take answers for it, or it was cancelled)."
                )
            }
            let comment = args["comment"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let e = try backend.respond(id: old.id, answer, comment: comment, future: future)
            let which = old.repeats == nil ? "" : future ? " and its later occurrences" : " (this occurrence)"
            let said = ["accepted": "Accepted", "tentative": "Said maybe to", "declined": "Declined"][answer.rawValue]!
            var r = ToolResult.text(
                "\(said) \(title(e))\(which), \(CalendarDates.span(e.start, e.end, allDay: e.allDay, zone: zone)) [\(e.calendar)]; "
                    + "the calendar's account tells \(e.organizer.map(MessagesCapability.quote) ?? "the organizer"). id \(e.id)\n"
                    + CalendarDates.zoneLine(zone, at: e.start) + "\n\n" + MessagesCapability.marking)
            r.activity = "Claude \(answer.verb) “\(e.title)” in \(e.calendar)"
            return r
        default:
            return .unknown("action", action, allowed: changeActions)
        }
    }

    /// ", repeats every day, 3 times" (or ", no longer repeats"), so the answer confirms the
    /// repeat asked for (a check couldn't tell from "Changed …" alone, 2026-11-02).
    static func repeating(_ e: EventInfo, zone: TimeZone, was old: EventInfo? = nil) -> String {
        if let r = e.repeats { return ", repeats \(r.describe(zone: zone))" }
        return old?.repeats != nil ? ", no longer repeats" : ""
    }

    private static func span(_ args: JSONValue) throws -> Bool {
        switch args["span"]?.stringValue {
        case nil, "", "this": false
        case "future": true
        case let s: throw ArgumentError(message: "span must be this or future (got \"\(s ?? "")\").")
        }
    }

    /// The event the id names, if its calendar can be changed (FR-704). Invitations from others
    /// can be changed and answered (FR-705, FR-707).
    private static func changeable(_ args: JSONValue, _ backend: any EventsBackend) throws -> EventInfo {
        guard let id = args["id"]?.stringValue, !id.isEmpty else {
            throw ArgumentError(message: "Give the event's id, from calendar_find.")
        }
        let e = try backend.event(id: id)
        guard e.writable else { throw EventsFailure.readOnlyCalendar(e.calendar) }
        return e
    }

    /// Whether the people to invite and uninvite fit the event (FR-706).
    private static func checkPeople(_ d: EventDraft, _ e: EventInfo) throws {
        guard !d.invite.isEmpty || !d.uninvite.isEmpty else { return }
        guard e.canInvite else {
            throw ArgumentError(
                message: e.ownEvent
                    ? "People can't be invited to events in \(e.calendar): its account doesn't send invitations (an On My Mac calendar, for instance). Move the event to an iCloud, Google, or Exchange calendar first."
                    : "\(title(e)) is an invitation from \(e.organizer.map(MessagesCapability.quote) ?? "someone else"), and the organizer doesn't let guests invite others."
            )
        }
        let emails = Set(e.attendees.compactMap { $0.email?.lowercased() })
        for gone in d.uninvite where !emails.contains(gone.lowercased()) {
            throw ArgumentError(
                message: "\(gone) isn't invited to “\(e.title)”. Invited: \(emails.sorted().joined(separator: ", ")).")
        }
    }

    /// "Invited a, b; their invitations go out from the calendar's account.\n"
    static func invited(_ d: EventDraft) -> String {
        var s = ""
        if !d.invite.isEmpty {
            s += "Invited \(d.invite.joined(separator: ", ")); the calendar's account sends the invitations.\n"
        }
        if !d.uninvite.isEmpty {
            s += "Uninvited \(d.uninvite.joined(separator: ", ")); the calendar's account tells them.\n"
        }
        return s
    }

    /// Email addresses from `key`, trimmed; each must look like one.
    static func emails(_ args: JSONValue, _ key: String) throws -> [String] {
        guard let value = args[key] else { return [] }
        guard case .array(let items) = value else {
            throw ArgumentError(message: "\(key) must be a list of email addresses.")
        }
        return try items.map { v in
            let s = v.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = s.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !s.contains(" ") else {
                throw ArgumentError(message: "\(key): “\(s)” isn't an email address.")
            }
            return s
        }
    }

    /// The fields the arguments set; nil when they set none.
    static func draft(_ args: JSONValue, zone: TimeZone, existing: EventInfo? = nil) throws -> EventDraft? {
        var d = EventDraft()
        var any = false
        let start = try CalendarDates.argument(args, "start", zone: zone)
        let end = try CalendarDates.argument(args, "end", zone: zone)
        let allDay = args["all_day"]?.boolValue ?? (start?.dateOnly == true ? true : nil)
        if let allDay {
            d.allDay = allDay
            any = true
        }
        let isAllDay = allDay ?? existing?.allDay ?? false
        if let start {
            d.start = start.date
            any = true
        }
        if let end {
            d.end = end.date
            any = true
        }
        if existing == nil, let s = d.start, d.end == nil {
            d.end = isAllDay ? s : s.addingTimeInterval(3600)
        }
        let checkStart = d.start ?? existing?.start
        if let s = checkStart, let e = d.end, isAllDay ? e < s : e <= s {
            throw ArgumentError(message: "The end must be after the start.")
        }
        if let c = args["calendar"]?.stringValue, !c.isEmpty {
            d.calendar = c
            any = true
        }
        for (key, path) in [("location", \EventDraft.location), ("notes", \.notes), ("url", \.url)] {
            if let s = args[key]?.stringValue {
                d[keyPath: path] = s.isEmpty ? .clear : .set(s)
                any = true
            }
        }
        if case .array(let items)? = args["alarms"] {
            let minutes = try items.map { v -> Int in
                guard case .number(let n) = v, n.isFinite, let m = Int(exactly: n), (0...40_320).contains(m) else {
                    throw ArgumentError(message: "alarms must be whole minutes before the start, 0 to 40320.")
                }
                return m
            }
            d.alarms = minutes.isEmpty ? .clear : .set(minutes)
            any = true
        }
        if let r = try repeats(args, zone: zone) {
            d.repeats = r
            any = true
        }
        if let t = args["title"]?.stringValue, !t.isEmpty { any = true }
        d.invite = try emails(args, "invite")
        d.uninvite = try emails(args, "uninvite")
        if !d.invite.isEmpty || !d.uninvite.isEmpty { any = true }
        return any ? d : nil
    }

    /// The repeat the arguments ask for, if any.
    static func repeats(_ args: JSONValue, zone: TimeZone) throws -> Change<Repeat>? {
        guard let f = args["repeat"]?.stringValue, !f.isEmpty else {
            if args.hasAny("repeat_every", "repeat_until", "repeat_count") {
                throw ArgumentError(
                    message:
                        "Give repeat (daily, weekly, monthly, yearly) with repeat_every, repeat_until, or repeat_count."
                )
            }
            return nil
        }
        if f == "none" { return .clear }
        guard Repeat.frequencies.contains(f) else {
            throw ArgumentError(message: "repeat must be one of: none, \(Repeat.frequencies.joined(separator: ", ")).")
        }
        var r = Repeat(frequency: f, interval: try args.integer("repeat_every", in: 1...999) ?? 1)
        r.until = try CalendarDates.argument(args, "repeat_until", zone: zone).map {
            // The whole last day counts.
            $0.dateOnly ? CalendarDates.calendar(zone).date(byAdding: .second, value: 86_399, to: $0.date)! : $0.date
        }
        r.count = try args.integer("repeat_count", in: 1...999)
        if r.until != nil && r.count != nil {
            throw ArgumentError(message: "Give repeat_until or repeat_count, not both.")
        }
        return .set(r)
    }

    // MARK: errors

    static func run(_ kind: EventsKind, _ body: () async throws -> ToolResult) async -> ToolResult {
        do { return try await body() } catch let e as ArgumentError {
            return .text(e.message, isError: true)
        } catch let f as EventsFailure {
            return .text(explain(f), isError: true)
        } catch {
            return .text("Latchkey couldn't do that: \(error.localizedDescription)", isError: true)
        }
    }

    static func explain(_ f: EventsFailure) -> String {
        switch f {
        case .noAccess(.events): noAccess
        case .noAccess(.reminders): RemindersCapability.noAccess
        case .notFound(let id): "Nothing has the id \(id) any more. Find it again (calendar_find or reminders_find)."
        case .noSuchCalendar(let name, let available):
            "There's no calendar or list named “\(name)”. There are: \(available.joined(separator: ", "))."
        case .readOnlyCalendar(let name): "“\(name)” is read-only: its events can't be changed on this Mac."
        case .failed(let why): "macOS didn't accept the change: \(why)"
        }
    }
}

extension JSONValue {
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
}
