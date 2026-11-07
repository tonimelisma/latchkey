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
        /// Changed after sending (FR-170); `originalText` is what it said first, when known.
        var edited = false
        var originalText: String? = nil
        /// Taken back by its sender ("Undo Send").
        var unsent = false
        /// The message this one replies to (an inline reply), and that message's text.
        var replyTo: String? = nil
        var replyToText: String? = nil
        /// Each person's current tapback: one per person, the latest, unless taken back.
        var reactions: [Reaction] = []
    }

    /// A tapback, as Messages records it (`associated_message_type` 2000–2007; 3000–3007 take it back).
    struct Reaction: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case love, like, dislike, laugh, emphasize, question
            case emoji(String)
            case sticker

            init?(code: Int, emoji: String?) {
                switch code % 1000 {
                case 0: self = .love
                case 1: self = .like
                case 2: self = .dislike
                case 3: self = .laugh
                case 4: self = .emphasize
                case 5: self = .question
                case 6: self = .emoji(emoji ?? "")
                case 7: self = .sticker
                default: return nil
                }
            }
        }
        var kind: Kind
        var fromMe: Bool
        /// Who reacted, when not the Mac's owner.
        var from: Participant?
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
    /// The message table's columns: those for reactions, replies, and edits are read when there.
    private let columns: Set<String>

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
        columns = Set(((try? SQLite.rows(db, "PRAGMA table_info(message)")) ?? []).compactMap { $0[1].text })
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

    // MARK: changing in Messages' window (plan D3b)

    /// A message as Messages' window shows it, to find it there.
    struct Located: Sendable, Equatable {
        var id: String
        var conversationID: String
        var isGroup: Bool
        var service: String
        var text: String
        var attachmentNames: [String]
        var fromMe: Bool
        var date: Date
        var unsent: Bool
        /// Later messages in the same conversation on the same side with the same text: the window
        /// shows them below this one.
        var laterSame: Int
        /// The Mac owner's current tapback on it.
        var myReaction: Reaction.Kind?
    }

    func locate(_ guid: String) throws -> Located? {
        let found: (Located, Int64)? = try locked {
            guard
                let r = try rows(
                    """
                    SELECT m.ROWID, c.guid, c.style, COALESCE(m.service, c.service_name, ''), m.text, m.attributedBody,
                      m.is_from_me, \(Self.seconds("m.date")), c.ROWID
                    FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
                    WHERE m.guid = ? AND COALESCE(m.associated_message_type, 0) = 0 LIMIT 1
                    """, bind: [.text(guid)]
                ).first
            else { return nil }
            var text = r[4].text ?? ""
            if text.isEmpty || text == "\u{FFFC}", let body = r[5].blob { text = AttributedBody.text(body) ?? text }
            let names = try rows(
                """
                SELECT a.transfer_name FROM attachment a JOIN message_attachment_join x ON x.attachment_id = a.ROWID
                WHERE x.message_id = ?
                """, bind: [.int(r[0].int ?? 0)]
            ).compactMap { $0[0].text }
            return (
                Located(
                    id: guid, conversationID: r[1].text ?? "", isGroup: r[2].int == 43, service: r[3].text ?? "",
                    text: Self.clean(text), attachmentNames: names, fromMe: r[6].int == 1,
                    date: Date(timeIntervalSinceReferenceDate: r[7].double ?? 0), unsent: false, laterSame: 0,
                    myReaction: nil), r[8].int ?? 0
            )
        }
        guard var (loc, chat) = found else { return nil }
        let decorated = try locked {
            try messageRows(where: "m.guid = ?", bind: [.text(guid)], limit: 1, titles: [:]).first
        }
        loc.unsent = decorated?.unsent ?? false
        loc.myReaction = decorated?.reactions.first(where: \.fromMe)?.kind
        // Same text, same side, later: counted in Swift, since much text is only in attributedBody.
        let later = try locked {
            try messageRows(
                where: "j.chat_id = ? AND m.is_from_me = ? AND \(Self.seconds("m.date")) > ?",
                bind: [.int(chat), .int(loc.fromMe ? 1 : 0), .double(loc.date.timeIntervalSinceReferenceDate)],
                limit: 500, titles: [:], keep: { Self.clean($0) == loc.text })
        }
        loc.laterSame = later.count
        return loc
    }

    /// What Messages' window shows for a conversation: its name, or its people.
    func identity(of id: String) throws -> ConversationIdentity? {
        try locked {
            guard let c = try rows("SELECT ROWID, display_name FROM chat WHERE guid = ?", bind: [.text(id)]).first
            else { return nil }
            let people = try participants()[c[0].int ?? 0] ?? []
            return ConversationIdentity(id: id, name: c[1].text.flatMap { $0.isEmpty ? nil : $0 }, participants: people)
        }
    }

    /// The newest row in the message table, to tell what Messages records after it.
    func lastRow() throws -> Int64 {
        try locked { try rows("SELECT COALESCE(MAX(ROWID), 0) FROM message").first?[0].int ?? 0 }
    }

    /// A tapback of this type (2000–2007 given, 3000–3007 taken back) on the message, recorded after
    /// `row`, by anyone: in a conversation with oneself Messages keeps only the copy that came back.
    func reactionRecorded(on guid: String, type: Int, after row: Int64) throws -> Bool {
        try locked {
            try rows(
                """
                SELECT associated_message_guid FROM message WHERE ROWID > ? AND associated_message_type = ?
                """, bind: [.int(row), .int(Int64(type))]
            ).contains { Self.reactionTarget($0[0].text ?? "") == guid }
        }
    }

    /// The outgoing message after `row` in a conversation (a reply when `replyingTo` is given), and
    /// whether it was sent.
    func outgoingRecorded(after row: Int64, conversation: String?, replyingTo: String?) throws -> (
        guid: String, outcome: Outcome?
    )? {
        try locked {
            var sql = """
                SELECT m.guid, \(columns.contains("error") ? "m.error" : "0"), \(columns.contains("is_sent") ? "m.is_sent" : "1")
                FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
                WHERE m.ROWID > ? AND m.is_from_me = 1 AND COALESCE(m.associated_message_type, 0) = 0
                """
            var bind: [SQLite.Value] = [.int(row)]
            if let conversation {
                sql += " AND c.guid = ?"
                bind.append(.text(conversation))
            }
            if let replyingTo, columns.contains("thread_originator_guid") {
                sql += " AND m.thread_originator_guid = ?"
                bind.append(.text(replyingTo))
            }
            guard let r = try rows(sql + " ORDER BY m.ROWID DESC LIMIT 1", bind: bind).first else { return nil }
            let outcome: Outcome? = (r[1].int ?? 0) != 0 ? .failed : ((r[2].int ?? 0) == 1 ? .sent : nil)
            return (r[0].text ?? "", outcome)
        }
    }

    /// The message now reads `text` and is marked edited.
    func editRecorded(_ guid: String, text: String) throws -> Bool {
        let m = try locked { try messageRows(where: "m.guid = ?", bind: [.text(guid)], limit: 1, titles: [:]).first }
        return m.map { $0.edited && $0.text == Self.clean(text) } ?? false
    }

    func isUnsent(_ guid: String) throws -> Bool {
        try locked { try messageRows(where: "m.guid = ?", bind: [.text(guid)], limit: 1, titles: [:]).first?.unsent }
            ?? false
    }

    /// No longer in any conversation: Messages moves deleted messages to Recently Deleted (their
    /// row stays, outside every conversation) or removes them.
    func isDeleted(_ guid: String) throws -> Bool {
        try locked {
            try rows(
                "SELECT 1 FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE m.guid = ?",
                bind: [.text(guid)]
            ).isEmpty
        }
    }

    /// The conversation shows no messages any more (deleted, or moved to Recently Deleted).
    func conversationIsEmpty(_ id: String) throws -> Bool {
        try locked {
            try rows(
                "SELECT 1 FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID WHERE c.guid = ? LIMIT 1",
                bind: [.text(id)]
            ).isEmpty
        }
    }

    /// The newest message in a conversation, to show the conversation by.
    func latestMessage(in id: String) throws -> String? {
        try locked {
            try rows(
                """
                SELECT m.guid FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
                JOIN chat c ON c.ROWID = j.chat_id WHERE c.guid = ? AND COALESCE(m.associated_message_type, 0) = 0
                ORDER BY \(Self.seconds("m.date")) DESC, m.ROWID DESC LIMIT 1
                """, bind: [.text(id)]
            ).first?[0].text
        }
    }

    /// The group whose members are exactly these numbers or addresses that got a message from this
    /// Mac after `row`.
    func groupRecorded(with handles: [String], after row: Int64) throws -> String? {
        let wanted = try locked { try handles.map { Set(try handleRows(matching: $0)) } }
        return try locked {
            let chats = try rows(
                """
                SELECT DISTINCT c.ROWID, c.guid FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
                JOIN chat c ON c.ROWID = j.chat_id WHERE m.ROWID > ? AND m.is_from_me = 1 AND c.style = 43
                """, bind: [.int(row)])
            for c in chats {
                let members = Set(
                    try rows("SELECT handle_id FROM chat_handle_join WHERE chat_id = ?", bind: [.int(c[0].int ?? 0)])
                        .compactMap { $0[0].int })
                if members.count == wanted.count, wanted.allSatisfy({ !$0.isDisjoint(with: members) }) {
                    return c[1].text
                }
            }
            return nil
        }
    }

    func groupName(_ id: String) throws -> String? {
        try locked {
            try rows("SELECT display_name FROM chat WHERE guid = ?", bind: [.text(id)]).first?[0].text
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The service Messages has seen this number or address on ("iMessage", "SMS", …), if any.
    func knownService(for handle: String) throws -> String? {
        try locked {
            let ids = try handleRows(matching: handle)
            guard !ids.isEmpty else { return nil }
            let services = try rows(
                "SELECT service FROM handle WHERE ROWID IN (\(ids.map(String.init).joined(separator: ",")))"
            ).compactMap { $0[0].text }
            return services.contains("iMessage") ? "iMessage" : services.first
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
        return try decorate(out)
    }

    /// Adds reactions, replies, edits, and unsending to messages read (FR-170).
    private func decorate(_ msgs: [Message]) throws -> [Message] {
        guard !msgs.isEmpty else { return msgs }
        let has = { self.columns.contains($0) }
        var out = msgs
        let ids = msgs.map(\.id)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        if has("date_edited") {
            let summary = has("message_summary_info") ? "message_summary_info" : "NULL"
            let rows = try rows(
                "SELECT guid, date_edited, \(summary), text IS NULL AND attributedBody IS NULL FROM message WHERE guid IN (\(marks)) AND COALESCE(date_edited, 0) <> 0",
                bind: ids.map { .text($0) })
            for r in rows {
                guard let i = out.firstIndex(where: { $0.id == r[0].text }) else { continue }
                let info = r[2].blob.flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                }
                if info?["rp"] != nil || (r[3].int == 1 && out[i].attachments.isEmpty) {
                    out[i].unsent = true
                } else {
                    out[i].edited = true
                    let versions = ((info?["ec"] as? [String: Any])?["0"] as? [[String: Any]]) ?? []
                    if versions.count > 1, let first = versions.first?["t"] as? Data,
                        let text = AttributedBody.text(first).map(Self.clean), text != out[i].text
                    {
                        out[i].originalText = text
                    }
                }
            }
        }
        if has("thread_originator_guid") {
            let rows = try rows(
                "SELECT guid, thread_originator_guid FROM message WHERE guid IN (\(marks)) AND thread_originator_guid IS NOT NULL",
                bind: ids.map { .text($0) })
            let targets = Array(Set(rows.compactMap { $0[1].text }))
            var texts: [String: String] = [:]
            if !targets.isEmpty {
                let q = Array(repeating: "?", count: targets.count).joined(separator: ",")
                for r in try self.rows(
                    "SELECT guid, text, attributedBody FROM message WHERE guid IN (\(q))",
                    bind: targets.map { .text($0) })
                {
                    var text = r[1].text ?? ""
                    if text.isEmpty || text == "\u{FFFC}", let body = r[2].blob {
                        text = AttributedBody.text(body) ?? text
                    }
                    texts[r[0].text ?? ""] = Self.clean(text)
                }
            }
            for r in rows {
                guard let i = out.firstIndex(where: { $0.id == r[0].text }), let target = r[1].text else { continue }
                out[i].replyTo = target
                out[i].replyToText = texts[target]
            }
        }
        if has("associated_message_guid") {
            let emoji = has("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
            let chats = Array(Set(msgs.map(\.conversationID)))
            let earliest = msgs.map(\.date).min() ?? .distantPast
            let q = Array(repeating: "?", count: chats.count).joined(separator: ",")
            // Only reactions in these conversations since the earliest message shown, oldest first,
            // so the latest per person wins.
            let rows = try rows(
                """
                SELECT m.associated_message_guid, m.associated_message_type, \(emoji), m.is_from_me, h.id
                FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE m.associated_message_type BETWEEN 2000 AND 3007 AND c.guid IN (\(q))
                  AND \(Self.seconds("m.date")) >= ?
                ORDER BY \(Self.seconds("m.date")), m.ROWID
                """,
                bind: chats.map { .text($0) } + [.double(earliest.timeIntervalSinceReferenceDate)])
            var current: [String: [(key: String, reaction: Reaction)]] = [:]
            for r in rows {
                guard let assoc = r[0].text, let code = r[1].int.map(Int.init) else { continue }
                let target = Self.reactionTarget(assoc)
                let fromMe = r[3].int == 1
                let handle = r[4].text
                let key = fromMe ? "me" : (handle ?? "?")
                var list = current[target] ?? []
                list.removeAll { $0.key == key }
                if code < 3000, let kind = Reaction.Kind(code: code, emoji: r[2].text) {
                    let from = fromMe ? nil : handle.map { Participant(handle: $0, name: contacts.name(for: $0)) }
                    list.append((key, Reaction(kind: kind, fromMe: fromMe, from: from)))
                }
                current[target] = list
            }
            for i in out.indices { out[i].reactions = (current[out[i].id] ?? []).map(\.reaction) }
        }
        return out
    }

    /// `p:0/GUID` (a part of the message) or `bp:GUID` names the message a reaction is on.
    static func reactionTarget(_ assoc: String) -> String {
        if let slash = assoc.firstIndex(of: "/") { return String(assoc[assoc.index(after: slash)...]) }
        if assoc.hasPrefix("bp:") { return String(assoc.dropFirst(3)) }
        return assoc
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

/// What the window must show before anything is pressed: the conversation's name, or its
/// people's names and numbers (security review 2026-11-05: never act on whatever is shown).
struct ConversationIdentity: Sendable, Equatable {
    var id: String
    /// The group's own name, if it has one.
    var name: String?
    var participants: [MessagesStore.Participant]
}

/// How to find one message in the window: Messages shows no ids there, so by its conversation,
/// its text (or file name), and its side. Only a single match is acted on.
