import Foundation

/// The changes EventKit can't make: flag, tags, parent, section (spec 007 FR-715 to FR-719).
struct ReminderExtrasChange: Sendable, Equatable {
    var flagged: Bool?
    /// The reminder's tags after the change (without #); empty removes them all.
    var tags: [String]?
    /// A reminder id to become a subtask of; clear makes it a reminder of its own again.
    var parent: Change<String> = .keep
    /// A section of the reminder's list; clear takes it out of its section.
    var section: Change<String> = .keep

    var isEmpty: Bool { flagged == nil && tags == nil && parent == .keep && section == .keep }
}

/// Reads flags, tags, subtasks, and sections from Reminders' database and makes those changes in
/// Reminders' window (spec 007 plan D7).
struct RemindersExtras: Sendable {
    var source: any RemindersExtrasSource
    var window: RemindersWindow

    static let none = RemindersExtras(source: NoRemindersExtras(), window: .unavailable)
    static let live = RemindersExtras(source: RemindersStore(root: RemindersStore.defaultRoot), window: .live)

    static let noDisk = """
        Latchkey can't read flags, tags, subtasks, or sections: it needs Full Disk Access (the Mac's \
        owner turns it on in Latchkey's Settings → Permissions).
        """

    static let lockedMac = """
        This Mac is locked, and flags, tags, subtasks, and sections can only be changed in the Reminders \
        app's window, which a locked Mac doesn't show. Nothing was changed. Other changes (title, notes, \
        due date, priority, link, completing) work while it's locked; these work once the Mac is unlocked.
        """

    /// What the change needs before anything is done, so a change is never half made: the
    /// database to check it, and an unlocked Mac for the window.
    func preflight(_ c: ReminderExtrasChange) throws -> RemindersSnapshot {
        guard let snap = source.snapshot() else { throw ArgumentError(message: Self.noDisk) }
        if !c.isEmpty, window.locked() { throw ArgumentError(message: Self.lockedMac) }
        return snap
    }

    /// Whether moving `id` to another list needs the window: a subtask leaves its parent first,
    /// and a reminder with subtasks takes them along (EventKit refuses to move it alone).
    func moveNeedsWindow(_ id: String, _ snap: RemindersSnapshot) -> Bool {
        let e = snap.extra(id)
        return e.parentID != nil || !e.subtaskIDs.isEmpty
    }

    private func check(_ test: @escaping @Sendable (RemindersSnapshot) -> Bool) async -> Bool {
        let source = source
        return await window.saved { source.snapshot().map(test) ?? false }
    }

    private func show(_ id: String, _ title: String) async throws {
        guard await window.show(id) else {
            throw ArgumentError(message: "Reminders' window didn't show “\(title)”, so nothing more was changed.")
        }
    }

    /// Makes the changes in order (parent, section, tags, flag), each checked in the database;
    /// answers what was done. Throws at the first that didn't take, saying what was done before.
    func apply(
        _ c: ReminderExtrasChange, to r: ReminderInfo, backend: any EventsBackend, snapshot: RemindersSnapshot
    ) async throws -> [String] {
        var done: [String] = []
        func fail(_ what: String) -> ArgumentError {
            ArgumentError(
                message: ([what] + (done.isEmpty ? [] : ["Done before that: " + done.joined(separator: "; ")]))
                    .joined(separator: " "))
        }
        let id = r.id
        switch c.parent {
        case .keep: break
        case .clear:
            if snapshot.extra(id).parentID != nil {
                try await show(id, r.title)
                guard window.act(.outdent), await check({ $0.extra(id).parentID == nil }) else {
                    throw fail("“\(r.title)” couldn't be taken out of its parent in Reminders' window.")
                }
                done.append("“\(r.title)” is no longer a subtask")
            }
        case .set(let parentID):
            let parent = try backend.reminder(id: parentID)
            try await makeSubtask(r, of: parent, backend: backend, snapshot: snapshot, fail: fail)
            done.append("“\(r.title)” is now a subtask of “\(parent.title)”")
        }
        switch c.section {
        case .keep: break
        case .clear:
            if snapshot.extra(id).section != nil {
                try await show(id, r.title)
                guard await window.menu(["File", "Move to Section", "None"]),
                    await check({ $0.extra(id).section == nil })
                else { throw fail("“\(r.title)” couldn't be taken out of its section.") }
                done.append("“\(r.title)” is in no section")
            }
        case .set(let name):
            let sections = snapshot.sections[r.listID] ?? []
            guard
                let section = sections.first(where: {
                    $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })
            else {
                throw fail(
                    sections.isEmpty
                        ? "\(r.list) has no sections."
                        : "\(r.list) has no section “\(name)”; its sections: "
                            + sections.joined(separator: ", ") + ".")
            }
            try await show(id, r.title)
            guard await window.menu(["File", "Move to Section", section]),
                await check({ $0.extra(id).section == section })
            else { throw fail("“\(r.title)” couldn't be moved to the section “\(section)”.") }
            done.append("“\(r.title)” is in the section “\(section)”")
        }
        if let wanted = c.tags {
            try await setTags(wanted, on: r, backend: backend, snapshot: snapshot, fail: fail)
            done.append(wanted.isEmpty ? "“\(r.title)” has no tags" : "tags: " + Self.tagText(wanted))
        }
        if let flag = c.flagged, snapshot.extra(id).flagged != flag {
            try await show(id, r.title)
            // Edit → Flag turns the flag on or off (its title may say Unflag when it's on).
            var pressed = await window.menu(["Edit", "Flag"])
            if !pressed { pressed = await window.menu(["Edit", "Unflag"]) }
            guard pressed, await check({ $0.extra(id).flagged == flag })
            else { throw fail("“\(r.title)” couldn't be \(flag ? "flagged" : "unflagged") in Reminders' window.") }
            done.append(flag ? "flagged" : "unflagged")
        }
        return done
    }

    static func tagText(_ tags: [String]) -> String { tags.map { "#" + $0 }.joined(separator: " ") }

    /// A tag as Reminders takes it: no #, no spaces.
    static func tagName(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }).replacingOccurrences(of: " ", with: "-")
    }

    private func setTags(
        _ wanted: [String], on r: ReminderInfo, backend: any EventsBackend, snapshot: RemindersSnapshot,
        fail: (String) -> ArgumentError
    ) async throws {
        let id = r.id
        let have = snapshot.extra(id).tags
        let lower = Set(have.map { $0.lowercased() })
        let add = wanted.filter { !lower.contains($0.lowercased()) }
        let removing = have.filter { h in !wanted.contains { $0.caseInsensitiveCompare(h) == .orderedSame } }
        if !removing.isEmpty {
            throw fail(
                "Latchkey can add tags but not remove them: the Reminders app offers no way to remove a tag that "
                    + "Latchkey can reach. Remove \(Self.tagText(removing)) in Reminders itself.")
        }
        guard !add.isEmpty else { return }
        try await show(id, r.title)
        // Typed into the title, "#name" becomes a tag; the title then goes back to what it was
        // (the tag stays: checked live 2026-11-05).
        let shown = window.title() ?? r.title
        guard window.retitle(shown + " " + Self.tagText(add)),
            await check({ s in
                add.allSatisfy { a in s.extra(id).tags.contains { $0.caseInsensitiveCompare(a) == .orderedSame } }
            })
        else { throw fail("Reminders' window didn't take the tags \(Self.tagText(add)) for “\(r.title)”.") }
        var d = ReminderDraft()
        d.title = r.title
        _ = try backend.updateReminder(id: id, d)
    }

    private func makeSubtask(
        _ r: ReminderInfo, of parent: ReminderInfo, backend: any EventsBackend, snapshot: RemindersSnapshot,
        fail: (String) -> ArgumentError
    ) async throws {
        let id = r.id
        let p = snapshot.extra(parent.id)
        guard parent.id != id else { throw fail("A reminder can't be its own subtask.") }
        guard p.parentID == nil else {
            throw fail("“\(parent.title)” is itself a subtask; Reminders has one level of subtasks.")
        }
        guard snapshot.extra(id).subtaskIDs.isEmpty else {
            throw fail("“\(r.title)” has subtasks of its own; Reminders has one level of subtasks.")
        }
        if snapshot.extra(id).parentID == parent.id { return }
        if parent.listID != r.listID {
            if snapshot.extra(id).parentID != nil {
                try await show(id, r.title)
                guard window.act(.outdent), await check({ $0.extra(id).parentID == nil }) else {
                    throw fail("“\(r.title)” couldn't be taken out of its parent first.")
                }
            }
            var d = ReminderDraft()
            d.list = parent.listID
            _ = try backend.updateReminder(id: id, d)
        }
        try await show(id, r.title)
        // At most one step per row, and a few more for the moves Reminders makes itself.
        for _ in 0..<(window.rows().count * 2 + 4) {
            switch ReminderRowPlan.next(window.rows(), parent: parent.title) {
            case .done:
                if await check({ $0.extra(id).parentID == parent.id }) { return }
                throw fail("Reminders put “\(r.title)” under another reminder titled “\(parent.title)”.")
            case .parentNotShown:
                // Reminders on macOS 27 drops the selection after an indent, so the window then
                // shows no selected row although the move took (live check 2026-11-07): what
                // Reminders saved decides.
                if await check({ $0.extra(id).parentID == parent.id }) { return }
                throw fail("Reminders' window doesn't show “\(parent.title)” beside “\(r.title)”.")
            case .indent: guard window.act(.indent) else { throw fail("Reminders didn't indent “\(r.title)”.") }
            case .outdent: guard window.act(.outdent) else { throw fail("Reminders didn't outdent “\(r.title)”.") }
            case .moveUp: guard window.act(.moveUp) else { throw fail("Reminders didn't move “\(r.title)” up.") }
            case .moveDown:
                guard window.act(.moveDown) else { throw fail("Reminders didn't move “\(r.title)” down.") }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw fail("“\(r.title)” couldn't be put under “\(parent.title)” in Reminders' window.")
    }

    /// Moves a reminder that is a subtask or has subtasks to another list, keeping them
    /// together: EventKit refuses to move a parent alone and drops the subtask links when they move
    /// together (checked live 2026-11-05), so the subtasks are put back under it in the window.
    func moveFamily(
        _ r: ReminderInfo, to list: String, backend: any EventsBackend, snapshot: RemindersSnapshot
    ) async throws -> ReminderInfo {
        let id = r.id
        let e = snapshot.extra(id)
        if e.parentID != nil {
            try await show(id, r.title)
            guard window.act(.outdent), await check({ $0.extra(id).parentID == nil }) else {
                throw ArgumentError(message: "“\(r.title)” couldn't be taken out of its parent; it wasn't moved.")
            }
        }
        let moved = try backend.moveReminders([id] + e.subtaskIDs, list: list)
        guard let parent = moved.first else { return r }
        var lost: [String] = []
        for child in moved.dropFirst() {
            do {
                try await makeSubtask(
                    child, of: parent, backend: backend, snapshot: source.snapshot() ?? snapshot,
                    fail: { ArgumentError(message: $0) })
            } catch { lost.append("“\(child.title)”") }
        }
        if !lost.isEmpty {
            throw ArgumentError(
                message: "Moved “\(r.title)” and its subtasks to \(parent.list), but Reminders' window didn't put "
                    + lost.joined(separator: ", ") + " back under it: they are reminders of their own in "
                    + "\(parent.list) now (give each parent: \(parent.id) to try again).")
        }
        return parent
    }
}
