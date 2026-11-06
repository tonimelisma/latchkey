import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// A Reminders database in the layout macOS 27 keeps (Core Data; the tables and columns seen
/// in a real store on 2026-11-05), so the reader is tested without anyone's real reminders.
enum RemindersFixture {
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "reminders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Data-TEST.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let memberships = """
            {"minimumSupportedVersion":20230430,"memberships":[{"modifiedOn":760062344.1,\
            "groupID":"S-DAIRY","memberID":"R-MILK"}]}
            """
        let sql = """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES (3,'REMCDList',2,0),(6,'REMCDListSection',5,0),
              (11,'REMCDHashtagLabel',0,0),(15,'REMCDAlarm',13,0),(25,'REMCDImageAttachment',22,0),
              (26,'REMCDURLAttachment',22,0),(32,'REMCDHashtag',13,0),(39,'REMCDReminder',0,0);
            CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZCOMPLETED INTEGER,
              ZFLAGGED INTEGER, ZMARKEDFORDELETION INTEGER, ZLIST INTEGER, ZPARENTREMINDER INTEGER,
              ZCKIDENTIFIER VARCHAR, ZTITLE VARCHAR);
            CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER,
              ZREMINDER INTEGER, ZREMINDER2 INTEGER, ZREMINDER3 INTEGER, ZHASHTAGLABEL INTEGER, ZNAME VARCHAR,
              ZNAME1 VARCHAR, ZURL VARCHAR);
            CREATE TABLE ZREMCDHASHTAGLABEL (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNAME VARCHAR,
              ZCANONICALNAME VARCHAR);
            CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER,
              ZCKIDENTIFIER VARCHAR, ZNAME VARCHAR, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA BLOB);
            CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER,
              ZLIST INTEGER, ZCKIDENTIFIER VARCHAR, ZDISPLAYNAME VARCHAR);
            INSERT INTO ZREMCDBASELIST VALUES (1,3,0,'L-SHOP','Groceries',CAST('\(memberships)' AS BLOB)),
              (2,3,0,'L-TODO','Reminders',NULL);
            INSERT INTO ZREMCDBASESECTION VALUES (1,6,0,1,'S-DAIRY','Dairy'),(2,6,0,1,'S-FRUIT','Produce'),
              (3,6,1,1,'S-GONE','Old section');
            INSERT INTO ZREMCDREMINDER VALUES (1,39,0,1,0,2,NULL,'R-TRIP','Pack for trip'),
              (2,39,0,0,0,2,1,'R-SOCKS','Socks'),(3,39,1,0,0,2,1,'R-PASS','Passport'),
              (4,39,0,0,0,1,NULL,'R-MILK','Milk'),(5,39,0,1,1,2,NULL,'R-DELETED','Gone');
            INSERT INTO ZREMCDHASHTAGLABEL VALUES (1,11,'travel','travel');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER3,ZHASHTAGLABEL,ZNAME1) VALUES
              (10,32,0,1,1,'travel'),(11,32,0,1,NULL,'family'),(12,32,1,1,NULL,'removed'),(13,32,0,4,NULL,'dairy');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER) VALUES (20,15,0,1);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER2) VALUES (21,25,0,1);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER2,ZURL) VALUES
              (22,26,0,1,'https://example.com/packing');
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(
                .fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: String(cString: sqlite3_errmsg(db))])
        }
        return dir
    }
}

@Suite struct RemindersStoreTests {
    @Test func readsFlagsTagsSubtasksSectionsAndAttachments() throws {
        let dir = try RemindersFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = try #require(RemindersStore(root: dir).snapshot())
        let trip = snap.extra("R-TRIP")
        #expect(trip.flagged)
        #expect(trip.tags == ["travel", "family"])
        #expect(trip.subtaskIDs == ["R-SOCKS", "R-PASS"])
        #expect(trip.images == 1)
        #expect(trip.links == ["https://example.com/packing"])
        #expect(snap.extra("R-SOCKS").parentID == "R-TRIP")
        #expect(snap.extra("R-MILK").section == "Dairy")
        #expect(snap.extra("R-MILK").tags == ["dairy"])
        #expect(snap.sections["L-SHOP"] == ["Dairy", "Produce"])
        #expect(snap.reminders["R-DELETED"] == nil)
    }

    @Test func noDatabaseIsUnknownNotEmpty() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString)")
        #expect(RemindersStore(root: missing).snapshot() == nil)
    }
}

@Suite struct ReminderRowPlanTests {
    func rows(_ spec: [(String, Int)], selected: String) -> [ReminderRow] {
        spec.map { ReminderRow(title: $0.0, level: $0.1, selected: $0.0 == selected) }
    }

    @Test func movesNextToTheParentThenIndents() {
        // New reminder at the bottom, the parent two reminders up.
        var r = rows([("Trip", 0), ("Socks", 1), ("Milk", 0), ("Bread", 0), ("New", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .moveUp)
        r = rows([("Trip", 0), ("Socks", 1), ("New", 0), ("Milk", 0), ("Bread", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .indent)
        r = rows([("Trip", 0), ("Socks", 1), ("New", 1), ("Milk", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .done)
    }

    @Test func movesDownOutdentsAndStopsWithoutTheParent() {
        var r = rows([("New", 0), ("Milk", 0), ("Trip", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .moveDown)
        r = rows([("Milk", 0), ("New", 1), ("Trip", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .outdent)
        r = rows([("Milk", 0), ("New", 0)], selected: "New")
        #expect(ReminderRowPlan.next(r, parent: "Trip") == .parentNotShown)
    }
}

/// Reminders' window and database in memory: indenting, moving rows, typing #tags, and the
/// menus change the same state the database answers from.
final class FakeRemindersApp: RemindersExtrasSource, @unchecked Sendable {
    struct Item {
        var id: String
        var title: String
        var level = 0
    }

    var items: [Item] = []
    var snap = RemindersSnapshot()
    var selected: String?
    var isLocked = false
    var readable = true
    var actions: [String] = []

    func snapshot() -> RemindersSnapshot? {
        guard readable else { return nil }
        var s = snap
        for (i, it) in items.enumerated() {
            var e = s.reminders[it.id] ?? ReminderExtra()
            e.parentID = it.level == 1 ? items[..<i].last { $0.level == 0 }?.id : nil
            e.subtaskIDs = []
            s.reminders[it.id] = e
        }
        for it in items { if let p = s.reminders[it.id]?.parentID { s.reminders[p]?.subtaskIDs.append(it.id) } }
        return s
    }

    var index: Int? { items.firstIndex { $0.id == selected } }

    var window: RemindersWindow {
        RemindersWindow(
            show: { id in
                self.selected = id
                if !self.items.contains(where: { $0.id == id }) { self.items.append(Item(id: id, title: id)) }
                return true
            },
            rows: {
                self.items.map { ReminderRow(title: $0.title, level: $0.level, selected: $0.id == self.selected) }
            },
            act: { action in
                guard let i = self.index else { return false }
                self.actions.append(action.rawValue)
                switch action {
                case .indent:
                    guard i > 0 else { return false }
                    self.items[i].level = 1
                case .outdent: self.items[i].level = 0
                case .moveUp:
                    guard i > 0 else { return false }
                    self.items.swapAt(i, i - 1)
                case .moveDown:
                    guard i + 1 < self.items.count else { return false }
                    self.items.swapAt(i, i + 1)
                }
                return true
            },
            retitle: { text in
                guard let i = self.index else { return false }
                self.items[i].title = text
                let tags = text.split(separator: " ").filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) }
                self.snap.reminders[self.items[i].id, default: ReminderExtra()].tags += tags
                return true
            },
            title: { self.index.map { self.items[$0].title } },
            menu: { path in
                guard let id = self.selected else { return false }
                self.actions.append(path.joined(separator: " → "))
                if path == ["Edit", "Flag"] {
                    self.snap.reminders[id, default: ReminderExtra()].flagged.toggle()
                    return true
                }
                if path.count == 3, path[1] == "Move to Section" {
                    self.snap.reminders[id, default: ReminderExtra()].section = path[2] == "None" ? nil : path[2]
                    return true
                }
                return false
            },
            menuItems: { _ in [] }, locked: { self.isLocked },
            saved: { check in check() })
    }

    var extras: RemindersExtras { RemindersExtras(source: self, window: window) }
}

@Suite struct RemindersExtrasToolTests {
    let fake = FakeEvents()
    let app = FakeRemindersApp()
    static let la = CalendarDatesTests.la

    init() {
        fake.reminderList = [
            ReminderInfo(id: "R-TRIP", title: "Pack for trip", list: "Reminders", listID: "L-TODO"),
            ReminderInfo(id: "R-SOCKS", title: "Socks", list: "Reminders", listID: "L-TODO"),
            ReminderInfo(id: "R-CALL", title: "Call mom", list: "Reminders", listID: "L-TODO"),
            ReminderInfo(id: "R-MILK", title: "Milk", list: "Groceries", listID: "L-SHOP"),
        ]
        app.items = [
            .init(id: "R-TRIP", title: "Pack for trip"), .init(id: "R-SOCKS", title: "Socks", level: 1),
            .init(id: "R-CALL", title: "Call mom"),
        ]
        app.snap.reminders["R-TRIP"] = ReminderExtra(flagged: true, tags: ["travel"])
        app.snap.sections["L-SHOP"] = ["Dairy", "Produce"]
    }

    func tool(_ name: String) throws -> ToolEntry {
        let all =
            RemindersCapability.readTools(backend: fake, zone: { Self.la }, extras: app.extras)
            + RemindersCapability.writeTools(backend: fake, zone: { Self.la }, extras: app.extras)
        return try #require(all.first { $0.tool.name == name })
    }

    func text(_ r: ToolResult) -> String {
        guard case .array(let items) = r.content else { return "" }
        return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    func change(_ args: [String: JSONValue]) async throws -> ToolResult {
        try await tool("reminders_change").handler(.object(args))
    }

    @Test func findShowsFlagsTagsAndSubtasksUnderTheirReminder() async throws {
        let t = text(try await tool("reminders_find").handler(.object([:])))
        #expect(t.contains("- ☐ Pack for trip [Reminders] ⚑ #travel (1 subtask)"), "\(t)")
        #expect(t.contains("\n  - ☐ Socks [Reminders]"), "\(t)")
        let byTag = text(try await tool("reminders_find").handler(.object(["query": .string("#travel")])))
        #expect(byTag.contains("Pack for trip") && !byTag.contains("Call mom"))
        let one = text(try await tool("reminders_find").handler(.object(["id": .string("R-TRIP")])))
        #expect(one.contains("Flagged: yes") && one.contains("Tags: #travel"))
        #expect(one.contains("Subtasks:\n- ☐ Socks [Reminders]"), "\(one)")
        let child = text(try await tool("reminders_find").handler(.object(["id": .string("R-SOCKS")])))
        #expect(child.contains("Subtask of: Pack for trip (id R-TRIP)"))
        let list = text(try await tool("reminders_find").handler(.object(["list": .string("Groceries")])))
        #expect(list.contains("Sections: Dairy, Produce."))
    }

    @Test func withoutTheDatabaseFindSaysItDoesntKnow() async throws {
        app.readable = false
        let t = text(try await tool("reminders_find").handler(.object(["id": .string("R-TRIP")])))
        #expect(t.contains("unknown (Latchkey needs Full Disk Access"))
        let r = try await change(["action": .string("update"), "id": .string("R-CALL"), "flagged": .bool(true)])
        #expect(r.isError && text(r).contains("Full Disk Access"))
    }

    @Test func createsASubtaskWithTagsAndAFlag() async throws {
        let r = try await change([
            "action": .string("create"), "title": .string("Charger"), "parent": .string("R-TRIP"),
            "tags": .array([.string("travel"), .string("#tech")]), "flagged": .bool(true),
        ])
        #expect(!r.isError, "\(text(r))")
        let id = try #require(fake.reminderList.last?.id)
        let e = try #require(app.snapshot()).extra(id)
        #expect(e.parentID == "R-TRIP")
        #expect(e.flagged)
        #expect(e.tags == ["travel", "tech"])
        // The #tags typed into the title are taken out again; the tags stay.
        #expect(fake.reminderList.last?.title == "Charger")
        #expect(text(r).contains("is now a subtask of “Pack for trip”"), "\(text(r))")
        // Moved up past "Call mom" to sit under the trip's subtasks, then indented.
        #expect(app.actions.prefix(2) == ["Move Up", "Indent"], "\(app.actions)")
    }

    @Test func aLockedMacChangesNothing() async throws {
        app.isLocked = true
        let r = try await change([
            "action": .string("update"), "id": .string("R-CALL"), "title": .string("Call dad"),
            "flagged": .bool(true),
        ])
        #expect(r.isError && text(r).contains("locked"))
        #expect(fake.reminderList[2].title == "Call mom")
        #expect(app.actions.isEmpty)
        // A change EventKit makes alone still works while locked.
        let plain = try await change(["action": .string("update"), "id": .string("R-CALL"), "notes": .string("x")])
        #expect(!plain.isError)
    }

    @Test func plainUpdatesKeepFlagsTagsAndSubtasks() async throws {
        let r = try await change(["action": .string("update"), "id": .string("R-TRIP"), "title": .string("Pack")])
        #expect(!r.isError)
        let e = try #require(app.snapshot()).extra("R-TRIP")
        #expect(e.flagged && e.tags == ["travel"] && e.subtaskIDs == ["R-SOCKS"])
        #expect(app.actions.isEmpty)
    }

    @Test func outdentsUnflagsAndMovesToASection() async throws {
        let out = try await change(["action": .string("update"), "id": .string("R-SOCKS"), "parent": .string("")])
        #expect(!out.isError && app.snapshot()?.extra("R-SOCKS").parentID == nil, "\(text(out))")
        let unflag = try await change([
            "action": .string("update"), "id": .string("R-TRIP"), "flagged": .bool(false),
        ])
        #expect(!unflag.isError && app.snapshot()?.extra("R-TRIP").flagged == false)
        let sec = try await change(["action": .string("update"), "id": .string("R-MILK"), "section": .string("dairy")])
        #expect(!sec.isError && app.snapshot()?.extra("R-MILK").section == "Dairy", "\(text(sec))")
        let none = try await change([
            "action": .string("update"), "id": .string("R-MILK"), "section": .string("Bakery"),
        ])
        #expect(none.isError && text(none).contains("Dairy, Produce"))
    }

    @Test func refusesWhatRemindersCantDo() async throws {
        let remove = try await change(["action": .string("update"), "id": .string("R-TRIP"), "tags": .array([])])
        #expect(remove.isError && text(remove).contains("#travel"))
        #expect(app.snapshot()?.extra("R-TRIP").tags == ["travel"])
        let deep = try await change([
            "action": .string("update"), "id": .string("R-CALL"), "parent": .string("R-SOCKS"),
        ])
        #expect(deep.isError && text(deep).contains("one level"))
        let own = try await change(["action": .string("update"), "id": .string("R-TRIP"), "parent": .string("R-CALL")])
        #expect(own.isError && text(own).contains("has subtasks of its own"))
    }

    @Test func movingAReminderWithSubtasksTakesThemAlong() async throws {
        let r = try await change(["action": .string("update"), "id": .string("R-TRIP"), "list": .string("Groceries")])
        #expect(!r.isError, "\(text(r))")
        #expect(
            fake.reminderList.filter { $0.listID == "L-SHOP" }.map(\.id).sorted() == ["R-MILK", "R-SOCKS", "R-TRIP"])
        #expect(app.snapshot()?.extra("R-SOCKS").parentID == "R-TRIP")
        app.isLocked = true
        let locked = try await change([
            "action": .string("update"), "id": .string("R-TRIP"), "list": .string("Reminders"),
        ])
        #expect(locked.isError && text(locked).contains("has subtasks"))
        #expect(fake.reminderList.first { $0.id == "R-TRIP" }?.listID == "L-SHOP")
    }
}
