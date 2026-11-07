import Foundation

/// The Owner's reminders (spec 007 US2), through EventKit (plan D2).
enum RemindersCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.reminders, title: "Reminders",
            summary: "See, add, complete, change, and delete reminders and lists",
            readTools: readTools(backend: EventKitBackend.shared, zone: { .current }, extras: .live),
            writeTools: writeTools(backend: EventKitBackend.shared, zone: { .current }, extras: .live))
    }

    static let noAccess = """
        Latchkey can't see the reminders: macOS hasn't allowed it. The Mac's owner can allow \
        Reminders in Latchkey's Settings → Permissions.
        """

    static let maxReminders = 200

    static func readTools(
        backend: any EventsBackend, zone: @escaping CalendarCapability.Zone, extras: RemindersExtras = .none
    ) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "reminders_find", title: "Find Reminders",
                    description: """
                        Lists and searches reminders in the Mac's Reminders, with each one's id. With id: that \
                        reminder in full, with its subtasks. With nothing: the lists with how many are open, then the \
                        open reminders (dated ones by due date first); subtasks stand indented under their reminder; \
                        ⚑ marks flagged ones, #name their tags. query matches title, notes, and tags; list limits to \
                        one list, names its sections, and says how many reminders it holds, open and completed. \
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
                handler: { args in
                    await CalendarCapability.run(.reminders) { try await find(args, backend, zone(), extras) }
                })
        ]
    }

    static let changeActions = ["create", "update", "complete", "uncomplete", "delete", "create_list", "delete_list"]

    static func writeTools(
        backend: any EventsBackend, zone: @escaping CalendarCapability.Zone, extras: RemindersExtras = .none
    ) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "reminders_change", title: "Change Reminders",
                    description: """
                        Creates, changes, completes, or deletes a reminder, or creates or deletes a list. action: \
                        create (title; notes, list, due, priority, url, repeat optional), update (id and only the fields to change), complete or uncomplete (id), delete \
                        (id; its subtasks go with it; it can't be undone), \
                        create_list (title), delete_list (list and reminder_count: how many reminders it holds, \
                        open and completed, as reminders_find with list says; the list and all its reminders are \
                        deleted and can't be brought back). due is a day (\(CalendarDates.accepted)); with a time, the Mac alerts then. An \
                        empty text clears a field. Flags, tags, subtasks, and sections are shown but can't be \
                        changed: that needs the Reminders app's window, which Latchkey doesn't use.
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
                        "reminder_count": .integerParam(
                            "For delete_list: how many reminders the list holds, open and completed"),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 15_000),
                handler: { args in
                    await CalendarCapability.run(.reminders) { try await change(args, backend, zone(), extras) }
                })
        ]
    }

    // MARK: find

    static func find(
        _ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone, _ extras: RemindersExtras = .none
    ) async throws -> ToolResult {
        guard backend.allowed(.reminders) else { throw EventsFailure.noAccess(.reminders) }
        var lines = [CalendarDates.zoneLine(zone)]
        let snap = extras.source.snapshot()
        if let id = args["id"]?.stringValue, !id.isEmpty {
            let r = try backend.reminder(id: id)
            let subtasks = (snap?.extra(id).subtaskIDs ?? []).compactMap { try? backend.reminder(id: $0) }
            let parent = snap?.extra(id).parentID.map { try? backend.reminder(id: $0) } ?? nil
            return .text(
                lines[0] + "\n\n"
                    + describe(r, zone: zone, extra: snap?.extra(id), parent: parent, subtasks: subtasks))
        }
        var lists: [String]?
        if let name = args["list"]?.stringValue, !name.isEmpty {
            let list = try backend.resolveCalendar(name, .reminders)
            lists = [list.id]
            let (open, done) = try await count(list.id, backend)
            lines.append("\(list.title) holds \(reminders(open + done)) (\(open) open, \(done) completed).")
            if let sections = snap?.sections[list.id], !sections.isEmpty {
                lines.append("Sections: " + sections.joined(separator: ", ") + ".")
            }
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
                ([r.title, r.notes ?? ""] + (snap?.extra(r.id).tags.map { "#" + $0 } ?? [])).contains {
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
        lines += nested(Array(found.prefix(limit)), snap).map { r, depth in
            String(repeating: "  ", count: depth) + "- " + line(r, zone: zone, extra: snap?.extra(r.id))
        }
        if snap == nil { lines.append("(Flags, tags, and subtasks unknown: Latchkey needs Full Disk Access.)") }
        if found.count > limit {
            lines.append("… and \(found.count - limit) more; raise limit (up to \(maxReminders)).")
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// Open and completed reminders in a list.
    static func count(_ listID: String, _ backend: any EventsBackend) async throws -> (open: Int, completed: Int) {
        let open = try await backend.reminders(completed: false, from: nil, to: nil, lists: [listID]).count
        let done = try await backend.reminders(completed: true, from: nil, to: nil, lists: [listID]).count
        return (open, done)
    }

    static func reminders(_ n: Int) -> String { n == 1 ? "1 reminder" : "\(n) reminders" }

    static func due(_ r: ReminderInfo, zone: TimeZone) -> String? {
        r.due.map { CalendarDates.format($0, day: !r.dueHasTime, zone: zone) }
    }

    /// Subtasks right after their reminder, one level in, when both are shown.
    static func nested(_ found: [ReminderInfo], _ snap: RemindersSnapshot?) -> [(ReminderInfo, Int)] {
        guard let snap else { return found.map { ($0, 0) } }
        let shown = Set(found.map(\.id))
        var out: [(ReminderInfo, Int)] = []
        for r in found {
            if let p = snap.extra(r.id).parentID, shown.contains(p) { continue }
            out.append((r, 0))
            let subtasks = snap.extra(r.id).subtaskIDs
            out += found.filter { subtasks.contains($0.id) }.map { ($0, 1) }
        }
        return out
    }

    static func line(_ r: ReminderInfo, zone: TimeZone, extra: ReminderExtra? = nil) -> String {
        var s = "\(r.completed ? "☑" : "☐") \(r.title) [\(r.list)]"
        if extra?.flagged == true { s += " ⚑" }
        if let tags = extra?.tags, !tags.isEmpty { s += " " + RemindersExtras.tagText(tags) }
        if let n = extra?.subtaskIDs.count, n > 0 { s += " (\(n) subtask\(n == 1 ? "" : "s"))" }
        if let d = due(r, zone: zone) {
            let late = !r.completed && (r.due ?? .distantFuture) < Date()
            s += " due \(d)\(late ? " (overdue)" : "")"
        }
        if let p = r.priorityName { s += " (\(p) priority)" }
        if r.repeats != nil { s += " (repeats)" }
        if r.completed, let at = r.completedAt { s += " completed \(CalendarDates.format(at, zone: zone))" }
        return s + " (id \(r.id))"
    }

    static func describe(
        _ r: ReminderInfo, zone: TimeZone, extra: ReminderExtra? = nil, parent: ReminderInfo? = nil,
        subtasks: [ReminderInfo] = []
    ) -> String {
        var lines = ["Title: \(r.title)", "List: \(r.list)", "Status: \(r.completed ? "completed" : "open")"]
        if let e = extra {
            if let s = e.section { lines.append("Section: \(s)") }
            lines.append("Flagged: \(e.flagged ? "yes" : "no")")
            if !e.tags.isEmpty { lines.append("Tags: " + RemindersExtras.tagText(e.tags)) }
            if let p = parent { lines.append("Subtask of: \(p.title) (id \(p.id))") }
            if e.images > 0 { lines.append("Images: \(e.images)") }
            if !e.links.isEmpty { lines.append("Attached links: " + e.links.joined(separator: ", ")) }
        } else {
            lines.append("Flag, tags, subtasks: unknown (Latchkey needs Full Disk Access to read them)")
        }
        if let at = r.completedAt, r.completed { lines.append("Completed: \(CalendarDates.format(at, zone: zone))") }
        if let d = due(r, zone: zone) { lines.append("Due: \(d)") }
        if let p = r.priorityName { lines.append("Priority: \(p)") }
        if let rep = r.repeats { lines.append("Repeats: \(rep.describe(zone: zone))") }
        if let u = r.url { lines.append("Link: \(u)") }
        if let n = r.notes { lines.append("Notes:\n\(n)") }
        if !subtasks.isEmpty {
            lines.append("Subtasks:")
            lines += subtasks.map { "- " + line($0, zone: zone) }
        }
        lines.append("id: \(r.id)")
        return lines.joined(separator: "\n")
    }

    // MARK: change

    static func change(
        _ args: JSONValue, _ backend: any EventsBackend, _ zone: TimeZone, _ extras: RemindersExtras = .none
    ) async throws -> ToolResult {
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
            let x = try extrasChange(args)
            // A subtask goes straight to its parent's list.
            if case .set(let p) = x.parent, d.list == nil { d.list = try backend.reminder(id: p).listID }
            let snap = x.isEmpty ? nil : try extras.preflight(x)
            let r = try backend.createReminder(d)
            let text = "Added “\(r.title)” to \(r.list)\(due(r, zone: zone).map { ", due \($0)" } ?? ""). id \(r.id)"
            let activity = "Claude added the reminder “\(r.title)” to \(r.list)"
            var extra: [String] = []
            if let snap {
                do {
                    extra = try await extras.apply(x, to: r, backend: backend, snapshot: snap)
                } catch let e as ArgumentError {
                    var partial = ToolResult.text(text + "\nBut: " + e.message, isError: true)
                    partial.activity = activity
                    partial.made = "the reminder “\(r.title)” in \(r.list)"
                    return partial
                }
            }
            var added = done(text + (extra.isEmpty ? "" : "\n" + extra.joined(separator: "; ") + "."), activity)
            added.made = "the reminder “\(r.title)” in \(r.list)"
            return added
        case "update":
            let reminderID = try id()
            var d = try draft(args, zone: zone)
            let x = try extrasChange(args)
            guard d != nil || !x.isEmpty else { throw ArgumentError(message: "Give at least one field to change.") }
            if let t = args["title"]?.stringValue, !t.isEmpty { d?.title = t }
            var r = try backend.reminder(id: reminderID)
            let snap = extras.source.snapshot()
            if !x.isEmpty { _ = try extras.preflight(x) }
            // Another list: a subtask or a reminder with subtasks moves with the window's help.
            if let list = d?.list, let snap, extras.moveNeedsWindow(reminderID, snap),
                try backend.resolveCalendar(list, .reminders).id != r.listID
            {
                throw ArgumentError(
                    message: "“\(r.title)” "
                        + (snap.extra(reminderID).parentID != nil ? "is a subtask" : "has subtasks")
                        + ", and moving it to another list would lose that: macOS drops the links, and only the "
                        + "Reminders app's window could put them back, which Latchkey doesn't use. Nothing was changed."
                )
            }
            if let draft = d, draft != ReminderDraft() { r = try backend.updateReminder(id: reminderID, draft) }
            var extra: [String] = []
            if !x.isEmpty, let now = extras.source.snapshot() {
                extra = try await extras.apply(x, to: r, backend: backend, snapshot: now)
                r = try backend.reminder(id: reminderID)
            }
            return done(
                "Changed “\(r.title)”: \(line(r, zone: zone, extra: extras.source.snapshot()?.extra(reminderID)))"
                    + (extra.isEmpty ? "" : "\n" + extra.joined(separator: "; ") + "."),
                "Claude changed the reminder “\(r.title)”")
        case "complete", "uncomplete":
            var d = ReminderDraft()
            d.completed = action == "complete"
            let r = try backend.updateReminder(id: try id(), d)
            return d.completed == true
                ? done("Completed “\(r.title)”.", "Claude completed “\(r.title)”")
                : done("Marked “\(r.title)” as not completed.", "Claude marked “\(r.title)” as not completed")
        case "delete":
            let old = try backend.reminder(id: try id())
            let subtasks = extras.source.snapshot()?.extra(old.id).subtaskIDs ?? []
            try backend.deleteReminder(id: old.id)
            var text = "Deleted “\(old.title)” from \(old.list)."
            if !subtasks.isEmpty {
                let left = subtasks.filter { (try? backend.reminder(id: $0)) != nil }
                text +=
                    left.isEmpty
                    ? " Its \(subtasks.count == 1 ? "subtask" : "\(subtasks.count) subtasks") went with it."
                    : " \(left.count) of its subtasks remain as reminders of their own."
            }
            return done(text, "Claude deleted the reminder “\(old.title)”")
        case "create_list":
            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                throw ArgumentError(message: "Give the new list's title.")
            }
            let c = try backend.createList(title: title)
            return done(
                "Created the list “\(c.title)” in \(c.account). id \(c.id)",
                "Claude created the reminder list “\(c.title)”")
        case "delete_list":
            guard let name = args["list"]?.stringValue, !name.isEmpty else {
                throw ArgumentError(message: "Give the list to delete (name or id), from reminders_find.")
            }
            let list = try backend.resolveCalendar(name, .reminders)
            guard list.writable else {
                throw ArgumentError(message: "“\(list.title)” is read-only: it can't be deleted on this Mac.")
            }
            let (open, completed) = try await count(list.id, backend)
            let holds = "“\(list.title)” holds \(reminders(open + completed)) (\(open) open, \(completed) completed)"
            guard let given = try args.integer("reminder_count", in: 0...Int.max) else {
                throw ArgumentError(
                    message: "Give reminder_count, how many reminders the list holds. \(holds); nothing was deleted.")
            }
            guard given == open + completed else {
                throw ArgumentError(
                    message: "reminder_count is \(given), but \(holds). Nothing was deleted; check the list first.")
            }
            try backend.deleteList(id: list.id)
            return done(
                "Deleted the list “\(list.title)” and its \(reminders(given)).",
                "Claude deleted the reminder list “\(list.title)” and its \(reminders(given))")
        default:
            return .unknown("action", action, allowed: changeActions)
        }
    }

    /// The flag, tags, parent, and section the arguments set: none since 2026-11-07 (they were set in
    /// the Reminders app's window, which drove an app the Owner may be using; Toni). Old arguments
    /// are refused rather than ignored.
    static func extrasChange(_ args: JSONValue) throws -> ReminderExtrasChange {
        for key in ["flagged", "tags", "parent", "section"] where args[key] != nil && args[key] != .null {
            throw ArgumentError(
                message:
                    "Latchkey can't change a reminder's \(key == "flagged" ? "flag" : key) any more: that needs the Reminders app's window, which it doesn't use. Nothing was changed."
            )
        }
        var x = ReminderExtrasChange()
        if let f = args["flagged"] {
            guard case .bool(let b) = f else { throw ArgumentError(message: "flagged must be true or false.") }
            x.flagged = b
        }
        let badTags = ArgumentError(message: "tags must be a list of names, like [\"errands\"].")
        switch args["tags"] {
        case nil, .null?: break
        case .array(let items)?:
            x.tags = try items.map { v in
                guard let t = v.stringValue.map(RemindersExtras.tagName), !t.isEmpty else { throw badTags }
                return t
            }
        case .string(let s)?:
            x.tags = s.split(whereSeparator: { $0 == "," || $0 == " " }).map { RemindersExtras.tagName(String($0)) }
                .filter { !$0.isEmpty }
        default: throw badTags
        }
        if let p = args["parent"]?.stringValue { x.parent = p.isEmpty ? .clear : .set(p) }
        if let sec = args["section"]?.stringValue { x.section = sec.isEmpty ? .clear : .set(sec) }
        return x
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
