import Foundation
import SQLite3

/// A chat as the WhatsApp tools show it, from either source (plan D5).
struct WhatsAppChat: Equatable, Sendable {
    var id: String
    var name: String
    var isGroup: Bool
    var unread: Int
    var last: Date?
    var lastText: String?
    /// Pinned in WhatsApp (it moves a pinned chat's sort date thousands of years ahead).
    var pinned = false
}

/// A message as the WhatsApp tools show it, from either source.
struct WhatsAppMessage: Equatable, Sendable {
    var id: String
    var chatID: String
    var chatName: String?
    var date: Date
    var fromMe: Bool
    var sender: String
    /// text, image, video, voice, document, sticker, location, contact, deleted, or other
    var kind: String
    var text: String
    var fileName: String?
}

/// Reads WhatsApp for Mac's own database, read-only (FR-1221). Needs Full Disk Access; works in
/// every screen state, locked included, but is only as current as the desktop app, which must be
/// running to keep it up to date.
final class WhatsAppStore: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case cannotOpen
        case unknownLayout(String)
    }

    static let folder = URL.homeDirectory.appending(
        path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    static let database = folder.appending(path: "ChatStorage.sqlite")
    /// WhatsApp's copy of the phone's address book: names for privacy ids (`…@lid`) that
    /// ChatStorage has only as numbers (a group sender showed as 88800011122244, 2026-11-03).
    static let addressBook = folder.appending(path: "ContactsV2.sqlite")

    private let db: OpaquePointer
    private let lock = NSLock()
    private let addressBookURL: URL
    private var names: [String: String] = [:]
    /// Phone number ↔ privacy id, from the address book: after a relink WhatsApp for Mac files most
    /// person chats under `…@lid` (47 of 60 on 2026-11-04), so a number alone doesn't find them.
    private var numberOfLID: [String: String] = [:]
    private var lidOfNumber: [String: String] = [:]
    private var namesRead = Date.distantPast

    init(url: URL = WhatsAppStore.database) throws {
        // Next to the database it belongs to (a test's copy has its own).
        addressBookURL = url.deletingLastPathComponent().appending(path: Self.addressBook.lastPathComponent)
        // `db` is set last: once every stored property is set, a throw runs `deinit`, which
        // closes it too, and a second close of a freed connection crashed the test host
        // (SQLite's "illegal multi-threaded access", 2026-11-03).
        let db: OpaquePointer
        do { db = try SQLite.openReadOnly(url) } catch { throw Failure.cannotOpen }
        // The columns Latchkey reads; another layout is said plainly rather than misread.
        for check in [
            "SELECT Z_PK, ZCONTACTJID, ZPARTNERNAME, ZSESSIONTYPE, ZUNREADCOUNT, ZLASTMESSAGEDATE, ZLASTMESSAGE, ZREMOVED, ZHIDDEN FROM ZWACHATSESSION LIMIT 0",
            "SELECT Z_PK, ZCHATSESSION, ZMESSAGEDATE, ZISFROMME, ZMESSAGETYPE, ZTEXT, ZFROMJID, ZGROUPMEMBER, ZMEDIAITEM, ZSTANZAID FROM ZWAMESSAGE LIMIT 0",
            "SELECT Z_PK, ZCONTACTNAME, ZFIRSTNAME, ZMEMBERJID FROM ZWAGROUPMEMBER LIMIT 0",
            "SELECT Z_PK, ZTITLE, ZMEDIALOCALPATH FROM ZWAMEDIAITEM LIMIT 0",
            "SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME LIMIT 0",
        ] {
            do { _ = try SQLite.rows(db, check) } catch {
                SQLite.close(db)
                throw Failure.unknownLayout((error as? SQLite.Failure)?.message ?? "\(error)")
            }
        }
        self.db = db
    }

    deinit { SQLite.close(db) }

    /// WhatsApp's dates are seconds since 2001.
    private static func date(_ v: SQLite.Value) -> Date? {
        guard case .null = v else { return Date(timeIntervalSinceReferenceDate: v.double ?? 0) }
        return nil
    }

    /// A chat's dates and preview come from its last message: `ZLASTMESSAGEDATE` is only a sort
    /// key (thousands of years ahead for a pinned chat, 2026-11-03), and `ZLASTMESSAGETEXT` is
    /// encoded, not text.
    private static let chatColumns = """
        s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, s.ZSESSIONTYPE, s.ZUNREADCOUNT,
        IFNULL(lm.ZMESSAGEDATE, s.ZLASTMESSAGEDATE), lm.ZTEXT, s.ZLASTMESSAGEDATE, lm.ZMESSAGETYPE
        """
    private static let chatFrom = "FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE lm ON lm.Z_PK = s.ZLASTMESSAGE"
    private static let chatOrder = "ORDER BY IFNULL(lm.ZMESSAGEDATE, s.ZLASTMESSAGEDATE) DESC"
    /// Chats people write in: not removed or hidden, not status updates or broadcast lists.
    private static let visible = """
        IFNULL(s.ZREMOVED, 0) = 0 AND IFNULL(s.ZHIDDEN, 0) = 0 AND s.ZCONTACTJID IS NOT NULL
        AND s.ZCONTACTJID NOT LIKE '%@status' AND s.ZCONTACTJID NOT LIKE '%@broadcast' AND s.ZSESSIONTYPE IN (0, 1)
        """

    private func chat(_ r: [SQLite.Value]) -> WhatsAppChat {
        let id = r[1].text ?? ""
        return WhatsAppChat(
            id: id, name: Self.clean(r[2].text) ?? id.components(separatedBy: "@").first ?? id,
            isGroup: r[3].int == 1 || id.hasSuffix("@g.us"), unread: max(0, Int(r[4].int ?? 0)), last: Self.date(r[5]),
            lastText: Self.clean(r[6].text) ?? r[8].int.map { "[\(Self.kind(Int($0)))]" },
            pinned: Self.date(r[7]).map { $0 > Date().addingTimeInterval(365 * 86400) } ?? false)
    }

    /// Chats newest first; `query` matches a name or a number.
    func chats(query: String?, unread: Bool, limit: Int, offset: Int) throws -> (total: Int, chats: [WhatsAppChat]) {
        var whereSQL = Self.visible
        var bind: [SQLite.Value] = []
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let digits = q.filter(\.isNumber)
            whereSQL += " AND (s.ZPARTNERNAME LIKE ? ESCAPE '\\'"
            bind.append(.text("%\(Self.escape(q))%"))
            if digits.count >= 4 {
                whereSQL += " OR s.ZCONTACTJID LIKE ?"
                bind.append(.text("%\(digits)%@%"))
                if let lid = locked({
                    refreshNames(); return lidOfNumber[digits]
                }) {
                    whereSQL += " OR s.ZCONTACTJID = ?"
                    bind.append(.text("\(lid)@lid"))
                }
            }
            whereSQL += ")"
        }
        if unread { whereSQL += " AND s.ZUNREADCOUNT > 0" }
        return try locked {
            let total =
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
                try SQLite.rows(db, "SELECT COUNT(*) \(Self.chatFrom) WHERE \(whereSQL)", bind: bind)
                .first?.first?.int ?? 0
            let rows = try SQLite.rows(
                db,
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
                "SELECT \(Self.chatColumns) \(Self.chatFrom) WHERE \(whereSQL) \(Self.chatOrder) LIMIT ? OFFSET ?",
                bind: bind + [.int(Int64(limit)), .int(Int64(offset))])
            return (Int(total), rows.map(chat))
        }
    }

    /// The chat for an id from `chats`, or by name: exact, else the only one containing it.
    func chat(_ key: String) throws -> Resolution {
        try locked {
            refreshNames()
            let k = key.trimmingCharacters(in: .whitespaces)
            // An id; or a phone number, under its number or its privacy id.
            var ids = [k]
            if k.range(of: #"^[+\d\s().-]+$"#, options: .regularExpression) != nil, k.filter(\.isNumber).count >= 7 {
                ids = chatIDsUnlocked(forNumber: k.filter(\.isNumber))
            }
            for id in ids {
                if let r = try SQLite.rows(
                    // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
                    db, "SELECT \(Self.chatColumns) \(Self.chatFrom) WHERE s.ZCONTACTJID = ? AND \(Self.visible)",
                    bind: [.text(id)]
                ).first {
                    return .one(chat(r))
                }
            }
            // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
            let all = try SQLite.rows(db, "SELECT \(Self.chatColumns) \(Self.chatFrom) WHERE \(Self.visible)")
                .map(chat)
            let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            let exact = all.filter { fold($0.name) == fold(k) }
            if exact.count == 1 { return .one(exact[0]) }
            let pool = exact.count > 1 ? exact : all.filter { fold($0.name).contains(fold(k)) }
            switch pool.count {
            case 0: return .none
            case 1: return .one(pool[0])
            default:
                return .several(Array(pool.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }.prefix(10)))
            }
        }
    }

    enum Resolution: Equatable {
        case one(WhatsAppChat)
        case several([WhatsAppChat])
        case none
    }

    private static let messageSQL = """
        SELECT m.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZTEXT,
          g.ZCONTACTNAME, g.ZFIRSTNAME, p.ZPUSHNAME, IFNULL(g.ZMEMBERJID, m.ZFROMJID), i.ZTITLE, s.ZSESSIONTYPE,
          i.ZMEDIALOCALPATH
        FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON m.ZCHATSESSION = s.Z_PK
        LEFT JOIN ZWAGROUPMEMBER g ON m.ZGROUPMEMBER = g.Z_PK
        LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = IFNULL(g.ZMEMBERJID, m.ZFROMJID)
        LEFT JOIN ZWAMEDIAITEM i ON m.ZMEDIAITEM = i.Z_PK
        """
    /// Group events and other system rows have their own types; they aren't messages people wrote.
    private static let written = "m.ZMESSAGETYPE NOT IN (6, 10)"

    private func message(_ r: [SQLite.Value]) -> WhatsAppMessage {
        let fromMe = r[4].int == 1
        let isGroup = r[12].int == 1
        let partner = Self.clean(r[2].text)
        let sender: String =
            fromMe
            ? "You"
            : (r[10].text.flatMap { names[Self.user($0)] } ?? Self.clean(r[7].text) ?? Self.clean(r[8].text)
                ?? Self.clean(r[9].text) ?? (isGroup ? nil : partner) ?? r[10].text.map(Self.user) ?? "Someone")
        let kind = Self.kind(Int(r[5].int ?? -1))
        let path = r[13].text
        return WhatsAppMessage(
            id: "\(r[0].int ?? 0)", chatID: r[1].text ?? "", chatName: partner, date: Self.date(r[3]) ?? .distantPast,
            fromMe: fromMe, sender: sender, kind: kind, text: Self.clean(r[6].text) ?? "",
            fileName: kind == "document"
                ? (Self.clean(r[11].text) ?? path.map { ($0 as NSString).lastPathComponent }) : nil)
    }

    /// WhatsApp for Mac's message types (`ZMESSAGETYPE`), as seen in its database.
    static func kind(_ t: Int) -> String {
        switch t {
        case 0: "text"
        case 1: "image"
        case 2: "video"
        case 3: "voice"
        case 4: "contact"
        case 5: "location"
        case 7: "text"  // a message with a link
        case 8: "document"
        case 11: "gif"
        case 14: "deleted"
        case 15: "sticker"
        default: "other"
        }
    }

    /// A chat's messages, newest first, before `before`.
    func messages(chat: String, before: Date?, limit: Int) throws -> [WhatsAppMessage] {
        try locked {
            var sql = "\(Self.messageSQL) WHERE s.ZCONTACTJID = ? AND \(Self.written)"
            var bind: [SQLite.Value] = [.text(chat)]
            if let before {
                sql += " AND m.ZMESSAGEDATE < ?"
                bind.append(.double(before.timeIntervalSinceReferenceDate))
            }
            sql += " ORDER BY m.ZMESSAGEDATE DESC LIMIT ?"
            bind.append(.int(Int64(limit)))
            refreshNames()
            // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
            return try SQLite.rows(db, sql, bind: bind).map(message)
        }
    }

    /// Messages whose text contains `text` (and within the dates, in one chat when given), newest first.
    func search(text: String?, chat: String?, since: Date?, until: Date?, limit: Int, offset: Int) throws
        -> [WhatsAppMessage]
    {
        try locked {
            var sql = "\(Self.messageSQL) WHERE \(Self.written)"
            var bind: [SQLite.Value] = []
            if let text, !text.isEmpty {
                sql += " AND m.ZTEXT LIKE ? ESCAPE '\\'"
                bind.append(.text("%\(Self.escape(text))%"))
            }
            if let chat {
                sql += " AND s.ZCONTACTJID = ?"
                bind.append(.text(chat))
            }
            if let since {
                sql += " AND m.ZMESSAGEDATE >= ?"
                bind.append(.double(since.timeIntervalSinceReferenceDate))
            }
            if let until {
                sql += " AND m.ZMESSAGEDATE < ?"
                bind.append(.double(until.timeIntervalSinceReferenceDate))
            }
            sql += " ORDER BY m.ZMESSAGEDATE DESC LIMIT ? OFFSET ?"
            bind += [.int(Int64(limit)), .int(Int64(offset))]
            refreshNames()
            // nosemgrep: scripts.semgrep.latchkey-sql-bound -- only fixed SQL constants are spliced in; every value is bound
            return try SQLite.rows(db, sql, bind: bind).map(message)
        }
    }

    /// The newest message's time: how current the database is (the desktop app may be closed).
    func newest() throws -> Date? {
        try locked {
            try SQLite.rows(db, "SELECT MAX(ZMESSAGEDATE) FROM ZWAMESSAGE").first.flatMap { Self.date($0[0]) }
        }
    }

    // MARK: helpers

    /// A WhatsApp id's user part, the key both databases share ("88800011122244@lid" → "88800011122244").
    static func user(_ jid: String) -> String { jid.components(separatedBy: "@").first ?? jid }

    /// The ids a person's chat may have, by phone number: `<number>@s.whatsapp.net`, and its
    /// privacy id when the address book knows it.
    func chatIDs(forNumber number: String) -> [String] {
        locked {
            refreshNames()
            return chatIDsUnlocked(forNumber: number)
        }
    }

    private func chatIDsUnlocked(forNumber number: String) -> [String] {
        ["\(number)@s.whatsapp.net"] + (lidOfNumber[number].map { ["\($0)@lid"] } ?? [])
    }

    /// A person's phone number for a chat id (by number or privacy id); nil for a group, or a privacy
    /// id the address book doesn't know.
    func number(forChat id: String) -> String? {
        if id.hasSuffix("@s.whatsapp.net") { return Self.user(id) }
        guard id.hasSuffix("@lid") else { return nil }
        return locked {
            refreshNames()
            return numberOfLID[Self.user(id)]
        }
    }

    /// Reads the address book's names, at most every five minutes; without it, names come from
    /// ChatStorage alone.
    private func refreshNames() {
        guard Date().timeIntervalSince(namesRead) > 300 else { return }
        namesRead = Date()
        guard let book = try? SQLite.openReadOnly(addressBookURL) else { return }
        defer { SQLite.close(book) }
        guard
            let rows = try? SQLite.rows(
                book, "SELECT ZFULLNAME, ZLID, ZWHATSAPPID FROM ZWAADDRESSBOOKCONTACT WHERE ZFULLNAME IS NOT NULL")
        else { return }
        var out: [String: String] = [:]
        for r in rows {
            guard let name = Self.clean(r[0].text) else { continue }
            for id in [r[1].text, r[2].text].compactMap({ $0 }) where !id.isEmpty { out[Self.user(id)] = name }
        }
        names = out
        var numbers: [String: String] = [:]
        var lids: [String: String] = [:]
        if let pairs = try? SQLite.rows(
            book,
            "SELECT ZLID, ZWHATSAPPID FROM ZWAADDRESSBOOKCONTACT WHERE ZLID IS NOT NULL AND ZWHATSAPPID IS NOT NULL")
        {
            for r in pairs {
                guard let lid = r[0].text.map(Self.user), let jid = r[1].text, jid.hasSuffix("@s.whatsapp.net") else {
                    continue
                }
                numbers[lid] = Self.user(jid)
                lids[Self.user(jid)] = lid
            }
        }
        numberOfLID = numbers
        lidOfNumber = lids
    }

    /// WhatsApp marks names with invisible direction characters ("\u{200E}You").
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.unicodeScalars.filter {
            !(0x200E...0x200F ~= $0.value || 0x202A...0x202E ~= $0.value || 0x2066...0x2069 ~= $0.value)
        }
        let out = String(String.UnicodeScalarView(t)).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
