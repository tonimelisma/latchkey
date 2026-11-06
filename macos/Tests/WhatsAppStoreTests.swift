import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// Spec 012 FR-1220, FR-1221: reading WhatsApp for Mac's database, in its layout as seen on
/// 2026-11-03 (Core Data, seconds since 2001), with a person, a group, a status row, a group event,
/// and names marked with invisible direction characters.
@Suite struct WhatsAppStoreTests {
    /// 2026-11-02 18:00 UTC as seconds since 2001.
    static let t0 = Date(timeIntervalSince1970: 1_794_160_800).timeIntervalSinceReferenceDate

    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "whatsapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "ChatStorage.sqlite")
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        defer { sqlite3_close(h) }
        let t = t0
        let sql = """
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER,
              ZUNREADCOUNT INTEGER, ZLASTMESSAGEDATE REAL, ZLASTMESSAGE INTEGER, ZREMOVED INTEGER, ZHIDDEN INTEGER);
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE REAL, ZISFROMME INTEGER,
              ZMESSAGETYPE INTEGER, ZTEXT TEXT, ZFROMJID TEXT, ZGROUPMEMBER INTEGER, ZMEDIAITEM INTEGER, ZSTANZAID TEXT,
              Z_OPT INTEGER DEFAULT 1);
            CREATE TABLE ZWAMESSAGEINFO (Z_PK INTEGER PRIMARY KEY, Z_OPT INTEGER, ZMESSAGE INTEGER, ZRECEIPTINFO BLOB);
            CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCONTACTNAME TEXT, ZFIRSTNAME TEXT, ZMEMBERJID TEXT);
            CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZMEDIALOCALPATH TEXT);
            CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID TEXT, ZPUSHNAME TEXT);
            INSERT INTO ZWACHATSESSION VALUES
              (1, '15550001111@s.whatsapp.net', 'Sarah Lee', 0, 0, \(t + 300), 2, 0, 0),
              (2, '120363000@g.us', 'Family', 1, 2, \(t + 500 + 6000 * 365.25 * 86400), 6, 0, 0),
              (3, '99900011122233@lid', '\u{200E}You', 0, 0, \(t + 100), NULL, 0, 0),
              (4, 'status@broadcast', NULL, 2, 0, \(t + 900), NULL, 0, 0),
              (5, '15550004444@s.whatsapp.net', 'Old Friend', 0, 0, \(t - 900), NULL, 1, 0);
            INSERT INTO ZWAGROUPMEMBER VALUES (1, 'Mum', NULL, '15550002222@s.whatsapp.net'), (2, NULL, NULL, '15550003333@s.whatsapp.net'),
              (3, NULL, NULL, '88800011122244@lid');
            INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, '15550003333@s.whatsapp.net', 'Dad');
            INSERT INTO ZWAMEDIAITEM VALUES (1, 'plan.pdf', 'Media/plan.pdf');
            INSERT INTO ZWAMESSAGE VALUES
              (1, 1, \(t + 290), 0, 0, 'see you at six', '15550001111@s.whatsapp.net', NULL, NULL, 'A', 1),
              (2, 1, \(t + 300), 1, 0, 'ok', NULL, NULL, NULL, 'B', 1),
              (3, 2, \(t + 400), 0, 6, NULL, NULL, 1, NULL, 'C', 1),
              (4, 2, \(t + 450), 0, 0, 'dinner saturday?', NULL, 1, NULL, 'D', 1),
              (5, 2, \(t + 480), 0, 8, NULL, NULL, 2, 1, 'E', 1),
              (6, 2, \(t + 500), 0, 0, 'yes 100%', NULL, 2, NULL, 'F', 1),
              (7, 2, \(t + 200), 0, 0, 'hearts', NULL, 3, NULL, 'G', 1);
            """
        #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
        // WhatsApp's address book: a name for a sender ChatStorage knows only by privacy id.
        var c: OpaquePointer?
        sqlite3_open(dir.appending(path: "ContactsV2.sqlite").path, &c)
        defer { sqlite3_close(c) }
        let book = """
            CREATE TABLE ZWAADDRESSBOOKCONTACT (Z_PK INTEGER PRIMARY KEY, ZFULLNAME TEXT, ZLID TEXT, ZWHATSAPPID TEXT);
            INSERT INTO ZWAADDRESSBOOKCONTACT VALUES (1, 'Pat Example', '88800011122244@lid', NULL);
            INSERT INTO ZWAADDRESSBOOKCONTACT VALUES (2, NULL, '99900011122233@lid', '15550009999@s.whatsapp.net');
            """
        #expect(sqlite3_exec(c, book, nil, nil, nil) == SQLITE_OK)
        // WhatsApp's own list of accounts it knows by privacy id and number (the Owner's among them).
        var l: OpaquePointer?
        sqlite3_open(dir.appending(path: "LID.sqlite").path, &l)
        defer { sqlite3_close(l) }
        let lid = """
            CREATE TABLE ZWAZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZPHONENUMBER TEXT, ZCOUNTRYCODE TEXT);
            INSERT INTO ZWAZACCOUNT VALUES (1, '99900011122233@lid', '15550009999', 'US');
            INSERT INTO ZWAZACCOUNT VALUES (2, '66600011122233@lid', '15550007777', NULL);
            """
        #expect(sqlite3_exec(l, lid, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func chatsAreNewestFirstWithoutStatusOrRemoved() throws {
        let s = try WhatsAppStore(url: try Self.make())
        let r = try s.chats(query: nil, unread: false, limit: 10, offset: 0)
        #expect(r.total == 3)
        #expect(r.chats.map(\.name) == ["Family", "Sarah Lee", "You"], "invisible marks removed")
        #expect(r.chats[0].isGroup && r.chats[0].unread == 2 && !r.chats[1].isGroup)
        // A pinned chat: the real time and text of its last message, marked pinned.
        #expect(r.chats[0].pinned && !r.chats[1].pinned)
        #expect(r.chats[0].last == Date(timeIntervalSinceReferenceDate: Self.t0 + 500))
        #expect(r.chats[0].lastText == "yes 100%" && r.chats[1].lastText == "ok")
        #expect(try s.chats(query: nil, unread: true, limit: 10, offset: 0).chats.map(\.name) == ["Family"])
        #expect(try s.chats(query: "sarah", unread: false, limit: 10, offset: 0).total == 1)
        #expect(try s.chats(query: "555-0001", unread: false, limit: 10, offset: 0).chats.first?.name == "Sarah Lee")
        #expect(try s.chats(query: nil, unread: false, limit: 1, offset: 1).chats.map(\.name) == ["Sarah Lee"])
    }

    /// After a relink most person chats are filed by privacy id (2026-11-04): a phone number finds
    /// them through WhatsApp's address book, and a privacy id gives its number back.
    @Test func aNumberFindsAChatFiledByPrivacyId() throws {
        let s = try WhatsAppStore(url: try Self.make())
        guard case .one(let c) = try s.chat("+1 (555) 000-9999") else {
            Issue.record("not found by number")
            return
        }
        #expect(c.id == "99900011122233@lid")
        #expect(s.number(forChat: "99900011122233@lid") == "15550009999")
        #expect(s.number(forChat: "15550001111@s.whatsapp.net") == "15550001111")
        #expect(s.number(forChat: "120363000@g.us") == nil && s.number(forChat: "88800011122244@lid") == nil)
        #expect(s.chatIDs(forNumber: "15550009999") == ["15550009999@s.whatsapp.net", "99900011122233@lid"])
        // A privacy id the address book doesn't know, from WhatsApp's own account list (the Owner's own
        // number is there, 2026-11-05).
        #expect(s.number(forChat: "66600011122233@lid") == "15550007777")
        let found = try s.chats(query: "15550009999", unread: false, limit: 5, offset: 0).chats.map(\.id)
        #expect(found == ["99900011122233@lid"])
    }

    @Test func aChatIsFoundByIdOrName() throws {
        let s = try WhatsAppStore(url: try Self.make())
        #expect(
            try s.chat("120363000@g.us")
                == .one(try #require(s.chats(query: "Family", unread: false, limit: 1, offset: 0).chats.first)))
        guard case .one(let c) = try s.chat("sarah lee") else { Issue.record("not found"); return }
        #expect(c.id == "15550001111@s.whatsapp.net")
        #expect(try s.chat("nobody") == .none)
        #expect(try s.chat("old friend") == .none, "a removed chat isn't offered")
    }

    @Test func messagesHaveSendersKindsAndNoGroupEvents() throws {
        let s = try WhatsAppStore(url: try Self.make())
        let m = try s.messages(chat: "120363000@g.us", before: nil, limit: 10)
        #expect(m.map(\.kind) == ["text", "document", "text", "text"], "newest first; the group event is left out")
        #expect(m[3].sender == "Pat Example", "a privacy id's name from WhatsApp's address book")
        #expect(m[0].sender == "Dad" && m[2].sender == "Mum", "a member's name, else their WhatsApp name")
        #expect(m[1].fileName == "plan.pdf")
        let person = try s.messages(chat: "15550001111@s.whatsapp.net", before: nil, limit: 10)
        #expect(person.map(\.sender) == ["You", "Sarah Lee"])
        #expect(person[0].date == Date(timeIntervalSinceReferenceDate: Self.t0 + 300))
        let older = try s.messages(
            chat: "120363000@g.us", before: Date(timeIntervalSinceReferenceDate: Self.t0 + 480), limit: 10)
        #expect(older.map(\.text) == ["dinner saturday?", "hearts"])
    }

    @Test func searchMatchesTextLiterallyWithinDates() throws {
        let s = try WhatsAppStore(url: try Self.make())
        #expect(
            try s.search(text: "SIX", chat: nil, since: nil, until: nil, limit: 10, offset: 0).map(\.text) == [
                "see you at six"
            ])
        #expect(try s.search(text: "100%", chat: nil, since: nil, until: nil, limit: 10, offset: 0).count == 1)
        #expect(
            try s.search(text: "%", chat: nil, since: nil, until: nil, limit: 10, offset: 0).count == 1,
            "% is a character, not a wildcard")
        let since = Date(timeIntervalSinceReferenceDate: Self.t0 + 400)
        #expect(
            try s.search(text: nil, chat: "120363000@g.us", since: since, until: nil, limit: 10, offset: 0).count == 3)
        #expect(try s.newest() == Date(timeIntervalSinceReferenceDate: Self.t0 + 500))
    }

    /// FR-1240: each message carries WhatsApp's own id (its stanza id), the same on both paths, and is
    /// found again by it.
    @Test func messagesCarryWhatsAppsOwnIdAndAreFoundByIt() throws {
        let s = try WhatsAppStore(url: try Self.make())
        let m = try s.messages(chat: "15550001111@s.whatsapp.net", before: nil, limit: 10)
        #expect(m.map(\.key) == ["B", "A"])
        let found = try #require(try s.message(chat: "15550001111@s.whatsapp.net", key: "A"))
        #expect(found.text == "see you at six" && !found.fromMe)
        #expect(try s.message(chat: "120363000@g.us", key: "A") == nil, "only in its own chat")
    }

    /// FR-1244: "me" is the Owner's own chat ("Message yourself", named You by WhatsApp).
    @Test func meIsTheOwnersOwnChat() throws {
        let s = try WhatsAppStore(url: try Self.make())
        for key in ["me", "myself", "Message yourself"] {
            guard case .one(let c) = try s.chat(key) else { Issue.record("\(key) not found"); continue }
            #expect(c.id == "99900011122233@lid")
        }
        #expect(s.ownChatID() == "99900011122233@lid")
    }

    /// Security review 2026-11-05: "me" is the Owner's own account (WhatsApp's account list), matched
    /// on the chat's id only; never a chat that is merely named You, and none when the account is unknown.
    @Test func meIsNeverFoundByName() throws {
        let url = try Self.make()
        var l: OpaquePointer?
        sqlite3_open(url.deletingLastPathComponent().appending(path: "LID.sqlite").path, &l)
        #expect(sqlite3_exec(l, "UPDATE ZWAZACCOUNT SET ZCOUNTRYCODE = NULL", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(l)
        let s = try WhatsAppStore(url: url)
        #expect(try s.chat("me") == .none, "the chat named You isn't taken for the Owner's own")
        #expect(s.ownChatID() == nil)
    }

    /// Security review 2026-11-05: a change through WhatsApp for Mac is confirmed on the message with
    /// that id: its stamp (row versions and receipts) changes when WhatsApp changes that message.
    @Test func aMessagesStampChangesWhenItChanges() throws {
        let url = try Self.make()
        let s = try WhatsAppStore(url: url)
        let before = try #require(s.stamp(chat: "15550001111@s.whatsapp.net", key: "A"))
        #expect(s.stamp(chat: "15550001111@s.whatsapp.net", key: "B") != nil)
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        #expect(
            sqlite3_exec(h, "UPDATE ZWAMESSAGE SET Z_OPT = Z_OPT + 1 WHERE ZSTANZAID = 'A'", nil, nil, nil) == SQLITE_OK
        )
        sqlite3_close(h)
        #expect(s.stamp(chat: "15550001111@s.whatsapp.net", key: "A") != before)
        #expect(s.stamp(chat: "120363000@g.us", key: "A") == nil, "only in its own chat")
    }

    /// Security review 2026-11-05: a reply sent through WhatsApp for Mac is confirmed to quote the
    /// intended message by its id, which WhatsApp keeps in the reply's media item metadata (seen
    /// 2026-11-05: the quoted stanza id at byte 3 of `ZWAMEDIAITEM.ZMETADATA`).
    @Test func aReplyIsKnownByTheMessageItQuotes() throws {
        let url = try Self.make()
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        let sql = """
            ALTER TABLE ZWAMEDIAITEM ADD COLUMN ZMETADATA BLOB;
            INSERT INTO ZWAMEDIAITEM VALUES (2, NULL, NULL, X'0A1441');
            INSERT INTO ZWAMESSAGE VALUES (9, 1, \(Self.t0 + 400), 1, 0, 'yes', NULL, NULL, 2, 'R', 1);
            """
        #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let s = try WhatsAppStore(url: url)
        #expect(s.quotes(chat: "15550001111@s.whatsapp.net", key: "R", quoted: "A"))
        #expect(!s.quotes(chat: "15550001111@s.whatsapp.net", key: "R", quoted: "B"))
        #expect(!s.quotes(chat: "15550001111@s.whatsapp.net", key: "B", quoted: "A"))
    }

    /// WhatsApp for Mac's database can hold the same message twice (two rows, one id, one chat;
    /// seen 2026-11-06 in the Owner's own chat), and every older message was then read twice.
    @Test func aMessageStoredTwiceIsReadOnce() throws {
        let url = try Self.make()
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        #expect(
            sqlite3_exec(
                h,
                "INSERT INTO ZWAMESSAGE VALUES (9, 1, \(Self.t0 + 290), 0, 0, 'see you at six', NULL, NULL, NULL, 'A', 1)",
                nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let s = try WhatsAppStore(url: url)
        let m = try s.messages(chat: "15550001111@s.whatsapp.net", before: nil, limit: 10)
        #expect(m.map(\.text) == ["ok", "see you at six"])
        let found = try s.search(
            text: "six", chat: nil, since: nil, until: nil, limit: 10, offset: 0)
        #expect(found.count == 1)
    }

    /// Security review 2026-11-05: messages that look the same (same chat, sender side, words, minute)
    /// are counted, so WhatsApp for Mac's window is never acted on when its bubble could be another.
    @Test func lookalikesAreCounted() throws {
        let url = try Self.make()
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        let t = Self.t0 + 295
        #expect(
            sqlite3_exec(
                h, "INSERT INTO ZWAMESSAGE VALUES (8, 1, \(t), 0, 0, 'see you at six', NULL, NULL, NULL, 'H', 0)", nil,
                nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let s = try WhatsAppStore(url: url)
        let a = try #require(try s.message(chat: "15550001111@s.whatsapp.net", key: "A"))
        let b = try #require(try s.message(chat: "15550001111@s.whatsapp.net", key: "B"))
        #expect(try s.lookalikes(a) == 2 && s.lookalikes(b) == 1)
    }

    @Test func anotherLayoutIsSaidPlainly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "whatsapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "ChatStorage.sqlite")
        var h: OpaquePointer?
        sqlite3_open(url.path, &h)
        sqlite3_exec(h, "CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY)", nil, nil, nil)
        sqlite3_close(h)
        #expect {
            _ = try WhatsAppStore(url: url)
        } throws: { error in
            if case WhatsAppStore.Failure.unknownLayout = error { return true }
            return false
        }
    }
}
