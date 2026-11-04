import Foundation

/// Reads Messages' own database (`chat.db`), read-only (plan D2). Reactions and system events
/// are left out; text comes from `text` or, on recent macOS, from `attributedBody`.
final class MessagesStore: @unchecked Sendable {
    struct Participant: Sendable, Equatable {
        var handle: String
        var name: String?

        var label: String { name.map { "\($0) (\(handle))" } ?? handle }
    }

    struct Conversation: Sendable, Equatable {
        var id: String
        /// The group's name, set by its members; nil for unnamed chats.
        var title: String?
        var participants: [Participant]
        var isGroup: Bool
        var service: String
        var lastDate: Date
        var lastText: String
        var lastFromMe: Bool

        var label: String { title ?? participants.map(\.label).joined(separator: ", ") }
    }

    struct Attachment: Sendable, Equatable {
        var id: String
        var name: String
        var mimeType: String

        var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    struct Message: Sendable, Equatable {
        var id: String
        var conversationID: String
        var conversationTitle: String?
        var date: Date
        var fromMe: Bool
        var sender: Participant?
        var text: String
        var attachments: [Attachment]
    }

    enum Failure: Error, Equatable {
        case cannotOpen
        case unknownLayout(String)
        case noSuchConversation(String)
        case noSuchAttachment(String)
        case notAnImage(String)
    }

    private let db: OpaquePointer
    private let contacts: any ContactsLookup
    private let lock = NSLock()

    init(url: URL, contacts: any ContactsLookup) throws {
        // `db` is set last: once every stored property is set, a throw runs `deinit`, which
        // closes it too, and a second close of a freed connection crashed the test host
        // (SQLite's "illegal multi-threaded access", 2026-11-03).
        let db: OpaquePointer
        do { db = try SQLite.openReadOnly(url) } catch { throw Failure.cannotOpen }
        self.contacts = contacts
        // Fail now, not at the first question, if the layout is not the one this reads.
        do {
            _ = try SQLite.rows(
                db, "SELECT ROWID, guid, text, attributedBody, handle_id, date, is_from_me FROM message LIMIT 0")
            _ = try SQLite.rows(db, "SELECT ROWID, guid, display_name, style, service_name FROM chat LIMIT 0")
        } catch let e as SQLite.Failure {
            SQLite.close(db)
            throw Failure.unknownLayout(e.message)
        } catch {
            SQLite.close(db)
            throw error
        }
        self.db = db
    }

    deinit { SQLite.close(db) }

    // MARK: queries

    func conversations(query: String?, limit: Int) throws -> [Conversation] {
        try locked {
            let handles = try participants()
            var chats: [(rowid: Int64, Conversation)] = []
            for r in try rows(
                """
                SELECT c.ROWID, c.guid, c.display_name, c.style, c.service_name,
                  (SELECT MAX(\(Self.seconds("j.message_date"))) FROM chat_message_join j WHERE j.chat_id = c.ROWID) AS last
                FROM chat c WHERE last IS NOT NULL ORDER BY last DESC
                """)
            {
                let rowid = r[0].int ?? 0
                let title = r[2].text.flatMap { $0.isEmpty ? nil : $0 }
                let convo = Conversation(
                    id: r[1].text ?? "", title: title, participants: handles[rowid] ?? [], isGroup: r[3].int == 43,
                    service: r[4].text ?? "", lastDate: Date(timeIntervalSinceReferenceDate: r[5].double ?? 0),
                    lastText: "", lastFromMe: false)
                if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
                    let haystack = [convo.title ?? ""] + convo.participants.flatMap { [$0.handle, $0.name ?? ""] }
                    guard
                        haystack.contains(where: {
                            $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        })
                    else { continue }
                }
                chats.append((rowid, convo))
                if chats.count >= limit { break }
            }
            return try chats.map { rowid, convo in
                var c = convo
                if let last = try messageRows(where: "j.chat_id = ?", bind: [.int(rowid)], limit: 1, titles: [:]).first
                {
                    c.lastText = last.text
                    c.lastFromMe = last.fromMe
                }
                return c
            }
        }
    }

    /// A conversation's messages before `before` (the latest when nil), oldest first.
    func messages(in conversation: String, before: Date?, limit: Int) throws -> [Message] {
        try locked {
            guard
                let chat = try rows("SELECT ROWID, display_name FROM chat WHERE guid = ?", bind: [.text(conversation)])
                    .first
            else { throw Failure.noSuchConversation(conversation) }
            var condition = "j.chat_id = ?"
            var bind: [SQLite.Value] = [.int(chat[0].int ?? 0)]
            if let before {
                condition += " AND \(Self.seconds("m.date")) < ?"
                bind.append(.double(before.timeIntervalSinceReferenceDate))
            }
            return try messageRows(where: condition, bind: bind, limit: limit, titles: [:]).reversed()
        }
    }

    /// Messages matching all given filters, newest first. `person` matches a name in Contacts, a
    /// number, or an address, and finds every conversation that person is in.
    func search(text: String?, person: String?, since: Date?, until: Date?, limit: Int) throws -> [Message] {
        try locked {
            var conditions: [String] = []
            var bind: [SQLite.Value] = []
            if let person = person?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
                let digits = ContactBook.digits(person)
                let ids = try rows("SELECT ROWID, id FROM handle").compactMap { r -> Int64? in
                    let handle = r[1].text ?? ""
                    let name = contacts.name(for: handle) ?? ""
                    let match =
                        name.range(of: person, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        || handle.localizedCaseInsensitiveContains(person)
                        || (digits.count >= 4 && ContactBook.digits(handle).contains(digits))
                    return match ? r[0].int : nil
                }
                guard !ids.isEmpty else { return [] }
                conditions.append(
                    "j.chat_id IN (SELECT chat_id FROM chat_handle_join WHERE handle_id IN (\(ids.map(String.init).joined(separator: ","))))"
                )
            }
            if let since {
                conditions.append("\(Self.seconds("m.date")) >= ?")
                bind.append(.double(since.timeIntervalSinceReferenceDate))
            }
            if let until {
                conditions.append("\(Self.seconds("m.date")) < ?")
                bind.append(.double(until.timeIntervalSinceReferenceDate))
            }
            let titles = Dictionary(
                try rows("SELECT guid, display_name FROM chat").compactMap { r in
                    r[1].text.flatMap { $0.isEmpty ? nil : (r[0].text ?? "", $0) }
                }, uniquingKeysWith: { a, _ in a })
            let q = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matcher = TextMatcher(q)
            let keep: ((String) -> Bool)? = q.isEmpty ? nil : { matcher.matches($0) }
            return try messageRows(
                where: conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), bind: bind, limit: limit,
                titles: titles,
                keep: keep)
        }
    }

    // MARK: sending (increment 5)

    func conversationExists(_ id: String) throws -> Bool {
        try locked { try !rows("SELECT 1 FROM chat WHERE guid = ?", bind: [.text(id)]).isEmpty }
    }

    /// The group whose name is `name`, if exactly one has it.
    func group(named name: String) throws -> String? {
        try locked {
            let hits = try rows(
                "SELECT guid FROM chat WHERE style = 43 AND display_name = ? COLLATE NOCASE", bind: [.text(name)])
            return hits.count == 1 ? hits[0][0].text : nil
        }
    }

    /// The most recent one-to-one conversation with this number or address.
    func conversation(with handle: String) throws -> String? {
        try locked {
            let ids = try handleRows(matching: handle)
            guard !ids.isEmpty else { return nil }
            let list = ids.map(String.init).joined(separator: ",")
            let last =
                "(SELECT MAX(\(Self.seconds("j.message_date"))) FROM chat_message_join j WHERE j.chat_id = c.ROWID)"
            return try rows(
                """
                SELECT c.guid FROM chat c JOIN chat_handle_join x ON x.chat_id = c.ROWID
                WHERE x.handle_id IN (\(list)) AND c.style <> 43 ORDER BY \(last) DESC LIMIT 1
                """
            ).first?[0].text
        }
    }

    enum Outcome: Equatable { case sent, failed }

    /// What Messages recorded for a message this Mac sent since `since` to the conversation or
    /// handle; nil while nothing is recorded yet.
    func outgoing(since: Date, conversation: String?, handle: String?) throws -> Outcome? {
        try locked {
            var target: [String] = []
            var bind: [SQLite.Value] = [.double(since.timeIntervalSinceReferenceDate)]
            if let conversation {
                target.append("c.guid = ?")
                bind.append(.text(conversation))
            }
            if let handle {
                let ids = try handleRows(matching: handle)
                if !ids.isEmpty { target.append("x.handle_id IN (\(ids.map(String.init).joined(separator: ",")))") }
            }
            guard !target.isEmpty else { return nil }
            let columns = Set(try rows("PRAGMA table_info(message)").compactMap { $0[1].text })
            let error = columns.contains("error") ? "m.error" : "0"
            let sent = columns.contains("is_sent") ? "m.is_sent" : "1"
            let sql = """
                SELECT \(error), \(sent) FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
                LEFT JOIN chat_handle_join x ON x.chat_id = c.ROWID
                WHERE m.is_from_me = 1 AND \(Self.seconds("m.date")) >= ? AND (\(target.joined(separator: " OR ")))
                ORDER BY m.ROWID DESC LIMIT 1
                """
            guard let r = try rows(sql, bind: bind).first else { return nil }
            if (r[0].int ?? 0) != 0 { return .failed }
            return (r[1].int ?? 0) == 1 ? .sent : nil
        }
    }

    /// Handle rows for a number (compared on digits, one ending with the other) or an address.
    private func handleRows(matching handle: String) throws -> [Int64] {
        let digits = ContactBook.digits(handle)
        let isAddress = handle.contains("@")
        return try rows("SELECT ROWID, id FROM handle").compactMap { r in
            let id = r[1].text ?? ""
            if isAddress { return id.caseInsensitiveCompare(handle) == .orderedSame ? r[0].int : nil }
            let d = ContactBook.digits(id)
            guard digits.count >= 7, d.count >= 7, !id.contains("@") else { return nil }
            return d.hasSuffix(digits) || digits.hasSuffix(d) ? r[0].int : nil
        }
    }

    func image(message: String, attachment: String) throws -> PreparedImage {
        let path: String = try locked {
            guard
                let r = try rows(
                    """
                    SELECT a.filename FROM attachment a
                    JOIN message_attachment_join x ON x.attachment_id = a.ROWID
                    JOIN message m ON m.ROWID = x.message_id
                    WHERE a.guid = ? AND m.guid = ?
                    """, bind: [.text(attachment), .text(message)]
                ).first, let path = r[0].text
            else { throw Failure.noSuchAttachment(attachment) }
            return (path as NSString).expandingTildeInPath
        }
        do { return try ImagePrep.prepare(URL(filePath: path)) } catch { throw Failure.notAnImage(attachment) }
    }

    // MARK: helpers

    /// Messages stores seconds since 2001 on older macOS and nanoseconds on newer.
    private static func seconds(_ column: String) -> String {
        "(CASE WHEN \(column) > 100000000000 THEN \(column) / 1000000000.0 ELSE \(column) END)"
    }

    private static let filters = "COALESCE(m.associated_message_type, 0) = 0 AND COALESCE(m.item_type, 0) = 0"

    private static let joins = """
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        """

    /// Messages, newest first, whose text passes `keep`, up to `limit`. With a filter, a first
    /// pass reads only the text, straight from SQLite's memory, so a search over a long history
    /// stays fast (FR-150); full details are then read for the matches.
    private func messageRows(
        where condition: String, bind: [SQLite.Value], limit: Int, titles: [String: String],
        keep: ((String) -> Bool)? = nil
    ) throws -> [Message] {
        var condition = condition
        var bind = bind
        if let keep {
            var ids: [Int64] = []
            // Only fixed fragments (joins, filters, seconds) and callers' conditions, which are fixed
            // text with `?` placeholders or Int64 row ids.
            let scan = """
                SELECT m.ROWID, m.text, m.attributedBody \(Self.joins)
                WHERE \(Self.filters) AND \(condition) ORDER BY \(Self.seconds("m.date")) DESC, m.ROWID DESC
                """
            // nosemgrep: latchkey-sql-bound -- `scan` is fixed fragments, `?`, and Int64 ids.
            try SQLite.forEachRaw(db, scan, bind: bind) { stmt in
                var text = SQLite.text(stmt, 1) ?? ""
                if text.isEmpty || text == "\u{FFFC}", let body = SQLite.blob(stmt, 2) {
                    text = AttributedBody.text(body) ?? text
                }
                if keep(text) { ids.append(SQLite.int(stmt, 0)) }
                return ids.count < limit
            }
            guard !ids.isEmpty else { return [] }
            condition = "m.ROWID IN (\(ids.map(String.init).joined(separator: ",")))"
            bind = []
        }
        let sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, \(Self.seconds("m.date")) AS secs,
              h.id, c.guid, m.cache_has_attachments
            \(Self.joins)
            WHERE \(Self.filters) AND \(condition)
            ORDER BY secs DESC, m.ROWID DESC
            """
        var out: [Message] = []
        // nosemgrep: latchkey-sql-bound -- `sql` is built as above: fixed fragments, `?`, Int64 ids.
        try SQLite.forEachRow(db, sql, bind: bind) { r in
            var text = r[2].text ?? ""
            if text.isEmpty || text == "\u{FFFC}", let body = r[3].blob { text = AttributedBody.text(body) ?? text }
            let fromMe = r[4].int == 1
            let handle = r[6].text
            let conversation = r[7].text ?? ""
            out.append(
                Message(
                    id: r[1].text ?? "", conversationID: conversation, conversationTitle: titles[conversation],
                    date: Date(timeIntervalSinceReferenceDate: r[5].double ?? 0), fromMe: fromMe,
                    sender: fromMe ? nil : handle.map { Participant(handle: $0, name: contacts.name(for: $0)) },
                    text: Self.clean(text), attachments: r[8].int == 1 ? try attachments(of: r[0].int ?? 0) : []))
            return out.count < limit
        }
        return out
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachments(of message: Int64) throws -> [Attachment] {
        try rows(
            """
            SELECT a.guid, a.transfer_name, a.mime_type FROM attachment a
            JOIN message_attachment_join x ON x.attachment_id = a.ROWID WHERE x.message_id = ?
            """, bind: [.int(message)]
        ).map { Attachment(id: $0[0].text ?? "", name: $0[1].text ?? "", mimeType: $0[2].text ?? "") }
    }

    private func participants() throws -> [Int64: [Participant]] {
        var out: [Int64: [Participant]] = [:]
        for r in try rows("SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id") {
            let handle = r[1].text ?? ""
            out[r[0].int ?? 0, default: []].append(Participant(handle: handle, name: contacts.name(for: handle)))
        }
        return out
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func rows(_ sql: String, bind: [SQLite.Value] = []) throws -> [[SQLite.Value]] {
        do { return try SQLite.rows(db, sql, bind: bind) } catch let e as SQLite.Failure {
            throw Failure.unknownLayout(e.message)
        }
    }
}

/// Case- and accent-insensitive "contains", fast for the common case of plain ASCII on both sides
/// (a byte comparison), and Foundation's full comparison otherwise.
struct TextMatcher: Sendable {
    let query: String
    private let ascii: [UInt8]?

    init(_ query: String) {
        self.query = query
        let bytes = Array(query.utf8)
        ascii = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.lower) : nil
    }

    func matches(_ text: String) -> Bool {
        if let ascii {
            var t = text
            if let hit = t.withUTF8({ b -> Bool? in
                guard b.allSatisfy({ $0 < 0x80 }) else { return nil }
                return Self.contains(b, ascii)
            }) {
                return hit
            }
        }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c + 0x20 : c }

    private static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard hay.count >= needle.count else { return false }
        let first = needle[0]
        for i in 0...(hay.count - needle.count) where lower(hay[i]) == first {
            var j = 1
            while j < needle.count, lower(hay[i + j]) == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        return false
    }
}
