import Foundation

/// What EventKit doesn't tell about a reminder: its flag, tags, parent and subtasks, section,
/// images, and attached links (spec 007 FR-714). Read from the Reminders database.
struct ReminderExtra: Sendable, Equatable {
    var flagged = false
    var tags: [String] = []
    /// The reminder it is a subtask of.
    var parentID: String?
    var subtaskIDs: [String] = []
    var section: String?
    var images = 0
    var links: [String] = []
}

/// Everything the Reminders database says beyond EventKit, at one moment.
struct RemindersSnapshot: Sendable, Equatable {
    /// By reminder id (EventKit's `calendarItemIdentifier`, the database's `ZCKIDENTIFIER`).
    var reminders: [String: ReminderExtra] = [:]
    /// Section names by list id, in the order the database keeps them.
    var sections: [String: [String]] = [:]

    func extra(_ id: String) -> ReminderExtra { reminders[id] ?? ReminderExtra() }
}

/// Where flags, tags, and subtasks come from; nil when they can't be read (no Full Disk Access).
protocol RemindersExtrasSource: Sendable {
    func snapshot() -> RemindersSnapshot?
}

/// No database: what tests of the plain tools and Macs without Full Disk Access get.
struct NoRemindersExtras: RemindersExtrasSource {
    func snapshot() -> RemindersSnapshot? { nil }
}

/// Reads the Reminders app's own databases, read-only, never writing them (research.md
/// "Flags, tags, and subtasks"). The layout is Core Data's: an entity's number and some column
/// names (`ZREMINDER3`, `ZNAME1`) differ between macOS versions, so they are looked up by name
/// in each file, and a column that isn't there only leaves that detail out.
struct RemindersStore: RemindersExtrasSource {
    var root: URL

    static let defaultRoot = URL.homeDirectory.appending(
        path: "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")

    func snapshot() -> RemindersSnapshot? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let files = names.filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }.sorted()
        var out = RemindersSnapshot()
        var opened = false
        for name in files {
            guard let db = try? SQLite.openReadOnly(root.appending(path: name)) else { continue }
            defer { SQLite.close(db) }
            opened = true
            Self.read(db, into: &out)
        }
        return opened ? out : nil
    }

    static func read(_ db: OpaquePointer, into out: inout RemindersSnapshot) {
        guard let rows = try? SQLite.rows(db, "SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") else { return }
        var entity: [String: Int64] = [:]
        for r in rows { if let e = r[0].int, let n = r[1].text { entity[n] = e } }

        // Reminders: id, flag, parent, list.
        guard
            let reminders = try? SQLite.rows(
                db,
                "SELECT Z_PK, ZCKIDENTIFIER, ZFLAGGED, ZPARENTREMINDER, ZLIST FROM ZREMCDREMINDER "
                    + "WHERE ZMARKEDFORDELETION = 0 AND ZCKIDENTIFIER IS NOT NULL ORDER BY Z_PK")
        else { return }
        var idOf: [Int64: String] = [:]
        for r in reminders { if let pk = r[0].int, let id = r[1].text { idOf[pk] = id } }
        var extras: [String: ReminderExtra] = [:]
        for r in reminders {
            guard let id = r[1].text else { continue }
            var e = ReminderExtra()
            e.flagged = (r[2].int ?? 0) != 0
            e.parentID = r[3].int.flatMap { idOf[$0] }
            extras[id] = e
        }
        for r in reminders {
            guard let id = r[1].text, let parent = r[3].int.flatMap({ idOf[$0] }) else { continue }
            extras[parent]?.subtaskIDs.append(id)
        }

        // Tags, images, and links are rows of ZREMCDOBJECT pointing at their reminder.
        let columns = Set(((try? SQLite.rows(db, "PRAGMA table_info(ZREMCDOBJECT)")) ?? []).compactMap { $0[1].text })
        let reminderColumns = columns.filter { $0.range(of: #"^ZREMINDER\d*$"#, options: .regularExpression) != nil }
            .sorted()
        if !reminderColumns.isEmpty {
            let owner =
                reminderColumns.count == 1 ? reminderColumns[0] : "COALESCE(\(reminderColumns.joined(separator: ", ")))"
            if let tag = entity["REMCDHashtag"] {
                let nameColumns = ["ZNAME1", "ZNAME"].filter(columns.contains)
                let label =
                    columns.contains("ZHASHTAGLABEL")
                    ? "(SELECT l.ZNAME FROM ZREMCDHASHTAGLABEL l WHERE l.Z_PK = o.ZHASHTAGLABEL)" : nil
                let name =
                    "COALESCE("
                    + ([label].compactMap { $0 } + nameColumns.map { "o.\($0)" } + ["NULL"]).joined(separator: ", ")
                    + ")"
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- column names come from the database's own table list; the value is bound
                let sql =
                    "SELECT \(owner), \(name) FROM ZREMCDOBJECT o WHERE o.Z_ENT = ? AND o.ZMARKEDFORDELETION = 0 ORDER BY o.Z_PK"
                for r in (try? SQLite.rows(db, sql, bind: [.int(tag)])) ?? [] {
                    guard let id = r[0].int.flatMap({ idOf[$0] }), let n = r[1].text, !n.isEmpty else { continue }
                    if extras[id]?.tags.contains(n) == false { extras[id]?.tags.append(n) }
                }
            }
            if let image = entity["REMCDImageAttachment"] {
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- column names come from the database's own table list; the value is bound
                let sql = "SELECT \(owner) FROM ZREMCDOBJECT o WHERE o.Z_ENT = ? AND o.ZMARKEDFORDELETION = 0"
                for r in (try? SQLite.rows(db, sql, bind: [.int(image)])) ?? [] {
                    if let id = r[0].int.flatMap({ idOf[$0] }) { extras[id]?.images += 1 }
                }
            }
            if let link = entity["REMCDURLAttachment"], columns.contains("ZURL") {
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- column names come from the database's own table list; the value is bound
                let sql = "SELECT \(owner), o.ZURL FROM ZREMCDOBJECT o WHERE o.Z_ENT = ? AND o.ZMARKEDFORDELETION = 0"
                for r in (try? SQLite.rows(db, sql, bind: [.int(link)])) ?? [] {
                    if let id = r[0].int.flatMap({ idOf[$0] }), let u = r[1].text { extras[id]?.links.append(u) }
                }
            }
        }

        // Sections: their names, and which reminder is in which (a JSON list kept on the list).
        var sectionName: [String: String] = [:]
        var listPK: [Int64: String] = [:]
        let lists =
            (try? SQLite.rows(
                db,
                "SELECT Z_PK, ZCKIDENTIFIER, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST "
                    + "WHERE ZMARKEDFORDELETION = 0")) ?? []
        for l in lists { if let pk = l[0].int, let id = l[1].text { listPK[pk] = id } }
        let sections =
            (try? SQLite.rows(
                db,
                "SELECT ZCKIDENTIFIER, ZDISPLAYNAME, ZLIST FROM ZREMCDBASESECTION "
                    + "WHERE ZMARKEDFORDELETION = 0 AND ZLIST IS NOT NULL ORDER BY Z_PK")) ?? []
        for s in sections {
            guard let id = s[0].text, let name = s[1].text, let list = s[2].int.flatMap({ listPK[$0] }) else {
                continue
            }
            sectionName[id] = name
            out.sections[list, default: []].append(name)
        }
        for l in lists {
            guard let data = l[2].blob ?? l[2].text.map({ Data($0.utf8) }),
                let doc = try? JSONDecoder().decode(Memberships.self, from: data)
            else { continue }
            for m in doc.memberships {
                if let name = sectionName[m.groupID], extras[m.memberID] != nil { extras[m.memberID]?.section = name }
            }
        }
        out.reminders.merge(extras) { a, _ in a }
    }

    struct Memberships: Decodable {
        struct Member: Decodable {
            var memberID: String
            var groupID: String
        }
        var memberships: [Member]
    }
}
