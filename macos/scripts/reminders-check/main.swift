// Runs Latchkey's real Reminders window and database code (RemindersWindow, RemindersStore,
// ReminderRowPlan) against the real Reminders app, in whatever screen state the Mac is in.
// Built by reminders-check.sh. Needs Reminders access (EventKit), Accessibility, and Full Disk
// Access, so run it from a program that has them.
//
// It makes one list, "Latchkey check <time> reminders", with three reminders, and checks in the
// database that: a reminder becomes a subtask (background Indent), a tag is added by typing
// "#name" and survives setting the title back through EventKit, the flag goes on and off (menu,
// Reminders forward for a moment), EventKit changes keep the flag, tag, and subtask, and a parent
// moved to another list with its subtask keeps it after the subtask is put back. Then it deletes
// what it made (also when a step fails or it is stopped), checks through EventKit and the database
// that nothing with the name is left, and fails if anything is.
import AppKit
import EventKit
import Foundation

let stamp = { () -> String in
    let f = DateFormatter()
    f.dateFormat = "MMdd-HHmmss"
    return f.string(from: Date())
}()
let tag = "Latchkey check \(stamp) reminders"
let store = EKEventStore()
let db = RemindersStore(root: RemindersStore.defaultRoot)
let window = RemindersWindow.live
var failures: [String] = []
var made: [EKCalendar] = []

func say(_ s: String) { print(s); fflush(stdout) }
func check(_ ok: Bool, _ what: String) {
    say((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures.append(what) }
}

func waitDB(_ test: (RemindersSnapshot) -> Bool) -> Bool {
    for _ in 0..<50 {
        if let s = db.snapshot(), test(s) { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

func cleanup() {
    for c in made { try? store.removeCalendar(c, commit: true) }
    made = []
    // A second route: EventKit's lists and reminders, and Reminders' database.
    store.reset()
    let lists = store.calendars(for: .reminder).filter { $0.title.hasPrefix(tag) }
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var strays: [String] = []
    store.fetchReminders(matching: store.predicateForReminders(in: nil)) { rs in
        strays = (rs ?? []).compactMap(\.title).filter { $0.hasPrefix(tag) }
        sem.signal()
    }
    sem.wait()
    var dbLeft = -1
    for _ in 0..<50 {
        if let s = db.snapshot() {
            _ = s
            dbLeft = listCount(tag)
            if dbLeft == 0 { break }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    check(lists.isEmpty && strays.isEmpty, "removed: no list or reminder named “\(tag)…” left in EventKit")
    check(dbLeft <= 0, "removed: no list named “\(tag)…” left in Reminders' database (\(dbLeft == -1 ? "unreadable" : "\(dbLeft)"))")
}

/// Lists in the database whose name starts with the prefix (not marked deleted).
func listCount(_ prefix: String) -> Int {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: RemindersStore.defaultRoot.path) else { return -1 }
    var n = 0
    for name in names where name.hasPrefix("Data-") && name.hasSuffix(".sqlite") {
        guard let h = try? SQLite.openReadOnly(RemindersStore.defaultRoot.appending(path: name)) else { continue }
        defer { SQLite.close(h) }
        let rows = (try? SQLite.rows(
            h, "SELECT COUNT(*) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND substr(ZNAME, 1, ?) = ?",
            bind: [.int(Int64(prefix.count)), .text(prefix)])) ?? []
        n += Int(rows.first?.first?.int ?? 0)
    }
    return n
}

for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        say("stopped: cleaning up")
        cleanup()
        exit(1)
    }
    source.resume()
    _ = Unmanaged.passRetained(source as AnyObject)
}

func list(_ title: String) throws -> EKCalendar {
    let c = EKCalendar(for: .reminder, eventStore: store)
    c.title = title
    c.source = store.defaultCalendarForNewReminders()!.source
    try store.saveCalendar(c, commit: true)
    made.append(c)
    return c
}

func reminder(_ title: String, in c: EKCalendar) throws -> EKReminder {
    let r = EKReminder(eventStore: store)
    r.title = title
    r.calendar = c
    try store.save(r, commit: true)
    return r
}

func run() async throws {
    guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
        say("FAIL no Reminders access")
        failures.append("access")
        return
    }
    say("locked: \(window.locked())")
    let a = try list(tag)
    let parent = try reminder("\(tag) parent", in: a)
    let other = try reminder("\(tag) other", in: a)
    let child = try reminder("\(tag) child", in: a)
    _ = other
    let p = parent.calendarItemIdentifier, c = child.calendarItemIdentifier
    check(waitDB { $0.reminders[c] != nil }, "database sees the new reminders")
    if window.locked() {
        check(!(await window.show(c)) || window.rows().isEmpty, "locked: the window shows no reminders (as expected)")
        return
    }

    // Subtask, in the background.
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    check(await window.show(c), "window shows the child")
    var steps = 0
    loop: while steps < 20 {
        steps += 1
        switch ReminderRowPlan.next(window.rows(), parent: parent.title!) {
        case .done: break loop
        case .indent: _ = window.act(.indent)
        case .outdent: _ = window.act(.outdent)
        case .moveUp: _ = window.act(.moveUp)
        case .moveDown: _ = window.act(.moveDown)
        case .parentNotShown:
            say("rows: \(window.rows())")
            break loop
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    check(waitDB { $0.extra(c).parentID == p }, "child is a subtask of parent (\(steps) steps)")
    check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == front, "Reminders stayed behind")

    // Tag, in the background, then the title back through EventKit.
    check(await window.show(p), "window shows the parent")
    let shown = window.title() ?? parent.title!
    check(window.retitle(shown + " #latchkeycheck"), "typed the tag")
    check(waitDB { $0.extra(p).tags.contains("latchkeycheck") }, "parent has the tag")
    store.reset()
    let p2 = store.calendarItem(withIdentifier: p) as! EKReminder
    say("title after typing: \(p2.title ?? "")")
    p2.title = "\(tag) parent"
    try store.save(p2, commit: true)
    check(waitDB { $0.extra(p).tags.contains("latchkeycheck") }, "tag kept after the title was set back")

    // Flag, with Reminders forward for a moment.
    say("Edit menu: \(window.menuItems(["Edit"]))")
    check(await window.show(p), "window shows the parent again")
    check(await window.menu(["Edit", "Flag"]), "pressed Edit → Flag")
    check(waitDB { $0.extra(p).flagged }, "parent is flagged")
    check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == front, "the previous app is in front again")

    // EventKit changes keep everything.
    p2.notes = "changed by the check"
    p2.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
    try store.save(p2, commit: true)
    let c2 = store.calendarItem(withIdentifier: c) as! EKReminder
    c2.title = "\(tag) child renamed"
    c2.priority = 1
    try store.save(c2, commit: true)
    check(
        waitDB { s in
            s.extra(p).flagged && s.extra(p).tags.contains("latchkeycheck") && s.extra(c).parentID == p
        }, "EventKit changes kept flag, tag, and subtask")

    // Tag removal: what the title field shows now, for the record.
    check(await window.show(p), "window shows the parent for the tag look")
    say("title field now: \(window.title() ?? "-")")

    // Move to another list with the subtask.
    let b = try list(tag + " B")
    p2.calendar = b
    c2.calendar = b
    try store.save(p2, commit: false)
    try store.save(c2, commit: false)
    try store.commit()
    check(waitDB { $0.extra(c).parentID == nil && $0.reminders[c] != nil }, "moved together: the link is dropped (as seen)")
    check(await window.show(c), "window shows the moved child")
    steps = 0
    loop2: while steps < 20 {
        steps += 1
        switch ReminderRowPlan.next(window.rows(), parent: p2.title!) {
        case .done: break loop2
        case .indent: _ = window.act(.indent)
        case .outdent: _ = window.act(.outdent)
        case .moveUp: _ = window.act(.moveUp)
        case .moveDown: _ = window.act(.moveDown)
        case .parentNotShown:
            say("rows: \(window.rows())")
            break loop2
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    check(waitDB { $0.extra(c).parentID == p && $0.extra(p).flagged }, "subtask back under the moved parent")

    // Flag off again.
    check(await window.show(p), "window shows the parent to unflag")
    check(await window.menu(["Edit", "Flag"]), "pressed Edit → Flag again")
    check(waitDB { !$0.extra(p).flagged }, "parent is unflagged")

    // Deleting the parent: what happens to the subtask.
    store.reset()
    try store.remove(store.calendarItem(withIdentifier: p) as! EKReminder, commit: true)
    store.reset()
    say("after deleting the parent, the subtask is \(store.calendarItem(withIdentifier: c) == nil ? "gone" : "still there")")
}

let task = Task {
    do { try await run() } catch {
        say("FAIL \(error)")
        failures.append("\(error)")
    }
    cleanup()
    say(failures.isEmpty ? "PASS" : "FAILED: \(failures.joined(separator: "; "))")
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
