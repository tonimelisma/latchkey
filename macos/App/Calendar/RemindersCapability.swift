import Foundation

/// The Owner's reminders (spec 007 US2), through EventKit (plan D2).
enum RemindersCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.reminders, title: "Reminders",
            summary: "See, add, complete, change, and delete reminders",
            readTools: readTools(backend: EventKitBackend.shared, zone: { .current }),
            writeTools: writeTools(backend: EventKitBackend.shared, zone: { .current }))
    }

    static let noAccess = """
        Latchkey can't see the reminders: macOS hasn't allowed it. The Mac's owner can allow \
        Reminders in Latchkey's Settings → Permissions.
        """

    static let maxReminders = 200

    static func readTools(backend: any EventsBackend, zone: @escaping CalendarCapability.Zone) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "reminders_find", title: "Find Reminders",
                    description: """
                        Lists and searches reminders in the Mac's Reminders, with each one's id. With id: that \
                        reminder in full. With nothing: the lists with how many are open, then the open reminders \
                        (dated ones by due date first). query matches title and notes; list limits to one list. \
                        Open reminders: to keeps those due by then. completed: true lists completed ones instead, \
                        from from (default 30 days ago) to to (default now). Dates: \(CalendarDates.accepted).
                        """,
                    input: [
                        "id": .stringParam("A reminder's id, to read it in full"),
                        "query": .stringParam("Words in the title or notes"),
                        "list": .stringParam("Only this list (name or id)"),
                        "completed": .boolParam("List completed reminders instead of open ones"),
                        "from": .stringParam("For completed: completed on or after"),
                        "to": .stringParam("Open: due by; completed: completed by"),
                        "limit": .integerParam("At most this many (default 50, up to 200)"),
                    ], readOnly: true, deadlineMS: 15_000),
                handler: { args in await CalendarCapability.run(.reminders) { try await find(args, backend, zone()) } })
        ]
    }

    static let changeActions = ["create", "update", "complete", "uncomplete", "delete", "create_list"]

    static func writeTools(backend: any EventsBackend, zone: @escaping CalendarCapability.Zone) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "reminders_change", title: "Change Reminders",
                    description: """
                        Creates, changes, completes, or deletes a reminder, or creates a list. action: create \
                        (title; notes, list, due, priority, url, repeat optional), update (id and only the fields \
                        to change), complete or uncomplete (id), delete (id; it can't be undone), create_list \
                        (title). due is a day (\(CalendarDates.accepted)); with a time, the Mac alerts then. An \
                        empty text clears a field. Flags, tags, and subtasks aren't available to apps.
                        """,
                    input: [
                        "action": .enumParam(changeActions, "What to do"),
                        "id": .stringParam("The reminder's id, from reminders_find"),
                        "title": .stringParam("The reminder's or new list's title"),
                        "notes": .stringParam("Notes"),
                        "list": .stringParam("The list (name or id; default the Mac's default list)"),
                        "due": .stringParam("When it's due"),
                        "priority": .enumParam(["none", "low", "medium", "high"], "Priority"),
                        "url": .stringParam("A link"),
                        "repeat": .enumParam(["none"] + Repeat.frequencies, "How it repeats; none stops repeating"),
                        "repeat_every": .integerParam("Repeat every this many days, weeks, … (default 1)"),
                        "repeat_until": .stringParam("Last day it repeats"),
                        "repeat_count": .integerParam("Or: how many times in all"),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 15_000),
                handler: { args in await CalendarCapability.run(.reminders) { try change(args, backend, zone()) } })
        ]
    }

    // MARK: find

    static func find(_ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone) async throws -> ToolResult {
        guard backend.allowed(.reminders) else { throw EventsFailure.noAccess(.reminders) }
        var lines = [CalendarDates.zoneLine(zone)]
        if let id = args["id"]?.stringValue, !id.isEmpty {
            return .text(lines[0] + "\n\n" + describe(try backend.reminder(id: id), zone: zone))
        }
        var lists: [String]?
        if let name = args["list"]?.stringValue, !name.isEmpty {
            lists = [try backend.resolveCalendar(name, .reminders).id]
        }
        let completed = args["completed"]?.boolValue == true
        let cal = CalendarDates.calendar(zone)
        let toArg = try CalendarDates.argument(args, "to", zone: zone).map {
            $0.dateOnly ? cal.date(byAdding: .day, value: 1, to: $0.date)! : $0.date
        }
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        var found: [ReminderInfo]
        if completed {
            let to = toArg ?? Date()
            let from =
                try CalendarDates.argument(args, "from", zone: zone)?.date
                ?? cal.date(byAdding: .day, value: -30, to: to)!
            guard to > from else { throw ArgumentError(message: "to must be after from.") }
            found = try await backend.reminders(completed: true, from: from, to: to, lists: lists)
            found.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        } else {
            found = try await backend.reminders(completed: false, from: nil, to: nil, lists: lists)
            if let toArg { found = found.filter { $0.due.map { $0 < toArg } ?? false } }
            found.sort { a, b in
                switch (a.due, b.due) {
                case (let x?, let y?): x < y
                case (.some, nil): true
                case (nil, .some): false
                default: a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
            }
        }
        if !query.isEmpty {
            found = found.filter { r in
                [r.title, r.notes ?? ""].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        if !args.hasAny("list", "query", "completed", "to", "from") {
            let open = try await backend.reminders(completed: false, from: nil, to: nil, lists: nil)
            lines.append("Lists:")
            lines += try backend.calendars(.reminders).map { c in
                let n = open.filter { $0.listID == c.id }.count
                return "- \(c.title) (\(c.account); \(n) open\(c.isDefault ? "; default" : ""); id \(c.id))"
            }
            lines.append("")
        }
        let limit = min(try args.integer("limit", in: 1...Int.max) ?? 50, maxReminders)
        lines.append(completed ? "Completed reminders:" : "Open reminders:")
        if found.isEmpty { lines.append("None.") }
        lines += found.prefix(limit).map { "- " + line($0, zone: zone) }
        if found.count > limit {
            lines.append("… and \(found.count - limit) more; raise limit (up to \(maxReminders)).")
        }
        return .text(lines.joined(separator: "\n"))
    }

    static func due(_ r: ReminderInfo, zone: TimeZone) -> String? {
        r.due.map { CalendarDates.format($0, day: !r.dueHasTime, zone: zone) }
    }

    static func line(_ r: ReminderInfo, zone: TimeZone) -> String {
        var s = "\(r.completed ? "☑" : "☐") \(r.title) [\(r.list)]"
        if let d = due(r, zone: zone) {
            let late = !r.completed && (r.due ?? .distantFuture) < Date()
            s += " due \(d)\(late ? " (overdue)" : "")"
        }
        if let p = r.priorityName { s += " (\(p) priority)" }
        if r.repeats != nil { s += " (repeats)" }
        if r.completed, let at = r.completedAt { s += " completed \(CalendarDates.format(at, zone: zone))" }
        return s + " (id \(r.id))"
    }

    static func describe(_ r: ReminderInfo, zone: TimeZone) -> String {
        var lines = ["Title: \(r.title)", "List: \(r.list)", "Status: \(r.completed ? "completed" : "open")"]
        if let at = r.completedAt, r.completed { lines.append("Completed: \(CalendarDates.format(at, zone: zone))") }
        if let d = due(r, zone: zone) { lines.append("Due: \(d)") }
        if let p = r.priorityName { lines.append("Priority: \(p)") }
        if let rep = r.repeats { lines.append("Repeats: \(rep.describe(zone: zone))") }
        if let u = r.url { lines.append("Link: \(u)") }
        if let n = r.notes { lines.append("Notes:\n\(n)") }
        lines.append("id: \(r.id)")
        return lines.joined(separator: "\n")
    }

    // MARK: change

    static func change(_ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone) throws -> ToolResult {
        guard backend.allowed(.reminders) else { throw EventsFailure.noAccess(.reminders) }
        let action = args["action"]?.stringValue
        func id() throws -> String {
            guard let id = args["id"]?.stringValue, !id.isEmpty else {
                throw ArgumentError(message: "Give the reminder's id, from reminders_find.")
            }
            return id
        }
        func done(_ text: String, _ activity: String) -> ToolResult {
            var r = ToolResult.text(text)
            r.activity = activity
            return r
        }
        switch action {
        case "create":
            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                throw ArgumentError(message: "Give the reminder's title.")
            }
            var d = try draft(args, zone: zone) ?? ReminderDraft()
            d.title = title
            let r = try backend.createReminder(d)
            return done(
                "Added “\(r.title)” to \(r.list)\(due(r, zone: zone).map { ", due \($0)" } ?? ""). id \(r.id)",
                "Claude added the reminder “\(r.title)” to \(r.list)")
        case "update":
            let reminderID = try id()
            guard var d = try draft(args, zone: zone) else {
                throw ArgumentError(message: "Give at least one field to change.")
            }
            if let t = args["title"]?.stringValue, !t.isEmpty { d.title = t }
            let r = try backend.updateReminder(id: reminderID, d)
            return done("Changed “\(r.title)”: \(line(r, zone: zone))", "Claude changed the reminder “\(r.title)”")
        case "complete", "uncomplete":
            var d = ReminderDraft()
            d.completed = action == "complete"
            let r = try backend.updateReminder(id: try id(), d)
            return d.completed == true
                ? done("Completed “\(r.title)”.", "Claude completed “\(r.title)”")
                : done("Marked “\(r.title)” as not completed.", "Claude marked “\(r.title)” as not completed")
        case "delete":
            let old = try backend.reminder(id: try id())
            try backend.deleteReminder(id: old.id)
            return done("Deleted “\(old.title)” from \(old.list).", "Claude deleted the reminder “\(old.title)”")
        case "create_list":
            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                throw ArgumentError(message: "Give the new list's title.")
            }
            let c = try backend.createList(title: title)
            return done(
                "Created the list “\(c.title)” in \(c.account). id \(c.id)",
                "Claude created the reminder list “\(c.title)”")
        default:
            return .unknown("action", action, allowed: changeActions)
        }
    }

    /// The fields the arguments set; nil when they set none.
    static func draft(_ args: JSONValue, zone: TimeZone) throws -> ReminderDraft? {
        var d = ReminderDraft()
        var any = args["title"]?.stringValue?.isEmpty == false
        for (key, path) in [("notes", \ReminderDraft.notes), ("url", \.url)] {
            if let s = args[key]?.stringValue {
                d[keyPath: path] = s.isEmpty ? .clear : .set(s)
                any = true
            }
        }
        if let l = args["list"]?.stringValue, !l.isEmpty {
            d.list = l
            any = true
        }
        if let s = args["due"]?.stringValue {
            d.due =
                s.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : .set(try CalendarDates.parse(s, zone: zone))
            any = true
        }
        if let p = args["priority"]?.stringValue {
            guard let value = ReminderInfo.priorities[p] else {
                throw ArgumentError(message: "priority must be none, low, medium, or high.")
            }
            d.priority = value
            any = true
        }
        if let r = try CalendarCapability.repeats(args, zone: zone) {
            d.repeats = r
            any = true
        }
        return any ? d : nil
    }
}
