import Foundation

/// Reads Apple Mail's Envelope Index and message files, read-only (spec 008 plan D2). Mail
/// needn't run; Latchkey needs Full Disk Access. Never writes: Mail's triggers keep its counts.
final class MailStore: @unchecked Sendable {
    struct Mailbox: Sendable, Equatable {
        var rowid: Int64
        var url: String
        /// Mail's scripting id of the account (the URL's host).
        var accountID: String
        /// The mailbox's path in its account, decoded ("[Gmail]/All Mail").
        var path: String
        var total: Int
        var unread: Int
        /// For a Gmail label: the All Mail mailbox that stores its messages.
        var source: Int64?

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var scheme: String { url.components(separatedBy: "://").first ?? "" }
    }

    struct Summary: Sendable, Equatable {
        var id: Int64
        var mailbox: Mailbox
        /// Gmail labels the message is listed under (Inbox, a label), when stored in All Mail.
        var labels: [Mailbox]
        var senderAddress: String
        var senderName: String
        var subject: String
        var date: Date
        var unread: Bool
        var flagged: Bool
        var hasAttachments: Bool
        var size: Int
        var conversation: Int64

        var sender: String {
            senderName.isEmpty || senderName == senderAddress ? senderAddress : "\(senderName) <\(senderAddress)>"
        }
        /// The mailbox to show and to address the message through: its first label other than
        /// All Mail, for Gmail (plan D6); otherwise where it is stored.
        var place: Mailbox { labels.first ?? mailbox }
    }

    struct Recipient: Sendable, Equatable {
        enum Kind: Int, Sendable { case to = 0, cc = 1, bcc = 2 }
        var kind: Kind
        var address: String
        var name: String

        var label: String { name.isEmpty || name == address ? address : "\(name) <\(address)>" }
    }

    struct Query: Sendable {
        var from: String?
        var to: String?
        var subject: String?
        /// Mail's account ids to look in (nil: every account).
        var accounts: [String]?
        var mailbox: String?
        var since: Date?
        var until: Date?
        var unread: Bool?
        var flagged: Bool?
        var hasAttachments: Bool?
    }

    enum Failure: Error, Equatable {
        case cannotOpen
        case unknownLayout(String)
        case noSuchMessage(Int64)
    }

    let root: URL
    private let db: OpaquePointer
    private let lock = NSLock()
    /// The folder name under each mailbox's `.mbox` that holds its messages: the index's UUID.
    let storeUUID: String

    /// The highest `V<n>` folder of Mail's data (V10 on macOS 14 to 27).
    static func defaultRoot(home: URL = .homeDirectory) -> URL? {
        let mail = home.appending(path: "Library/Mail")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? []
        let versions = names.compactMap { n -> Int? in n.hasPrefix("V") ? Int(n.dropFirst()) : nil }
        return versions.max().map { mail.appending(path: "V\($0)") }
    }

    static func indexURL(_ root: URL) -> URL { root.appending(path: "MailData/Envelope Index") }

    init(root: URL) throws {
        self.root = root
        do { db = try SQLite.openReadOnly(Self.indexURL(root)) } catch { throw Failure.cannotOpen }
        do {
            let props = try SQLite.rows(db, "SELECT key, value FROM properties")
            func prop(_ k: String) -> String? {
                guard let row = props.first(where: { $0[0].text == k }) else { return nil }
                return (row[1].text ?? row[1].int.map { String($0) })?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "'"))
            }
            guard let version = prop("version") else { throw Failure.unknownLayout("no version") }
            guard version == "4" else { throw Failure.unknownLayout("database version \(version)") }
            storeUUID = prop("UUID") ?? ""
            for sql in Self.layoutChecks { _ = try SQLite.rows(db, sql) }
        } catch let f as Failure {
            SQLite.close(db)
            throw f
        } catch {
            SQLite.close(db)
            throw Failure.unknownLayout("\(error)")
        }
    }

    deinit { SQLite.close(db) }

    /// Every column this reads, so a changed layout fails at open (FR-834).
    static let layoutChecks = [
        """
        SELECT ROWID, global_message_id, sender, subject_prefix, subject, date_received, mailbox, read, flagged,
          deleted, size, conversation_id FROM messages LIMIT 0
        """,
        "SELECT ROWID, url, total_count, unread_count, source FROM mailboxes LIMIT 0",
        "SELECT ROWID, address, comment FROM addresses LIMIT 0",
        "SELECT ROWID, subject FROM subjects LIMIT 0",
        "SELECT message, address, type, position FROM recipients LIMIT 0",
        "SELECT message, attachment_id, name FROM attachments LIMIT 0",
        "SELECT message_id, mailbox_id FROM labels LIMIT 0",
        "SELECT ROWID, message_id_header FROM message_global_data LIMIT 0",
    ]

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: mailboxes

    func mailboxes() throws -> [Mailbox] {
        try locked { try loadMailboxes() }
    }

    private var cachedMailboxes: (at: Date, list: [Mailbox])?

    private func loadMailboxes() throws -> [Mailbox] {
        if let c = cachedMailboxes, Date().timeIntervalSince(c.at) < 30 { return c.list }
        let list = try SQLite.rows(
            db, "SELECT ROWID, url, total_count, unread_count, source FROM mailboxes ORDER BY url"
        )
        .compactMap { r -> Mailbox? in
            guard let url = r[1].text, let parts = Self.split(url) else { return nil }
            return Mailbox(
                rowid: r[0].int ?? 0, url: url, accountID: parts.account, path: parts.path,
                total: Int(r[2].int ?? 0), unread: Int(r[3].int ?? 0), source: r[4].int)
        }
        cachedMailboxes = (Date(), list)
        return list
    }

    /// "imap://UUID/%5BGmail%5D/All%20Mail" → ("UUID", "[Gmail]/All Mail").
    static func split(_ url: String) -> (account: String, path: String)? {
        guard let r = url.range(of: "://") else { return nil }
        let rest = url[r.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return (String(rest), "") }
        let path = String(rest[rest.index(after: slash)...])
        return (String(rest[..<slash]), path.removingPercentEncoding ?? path)
    }

    /// The commonest sender address in an account's sent mailboxes, to name it when Mail can't
    /// be asked (research "Low-level choices").
    func ownAddress(account: String) throws -> String? {
        try locked {
            let sent = try loadMailboxes().filter { $0.accountID == account && Self.looksSent($0.name) }
            guard !sent.isEmpty else { return nil }
            let ids = sent.map { String($0.rowid) }.joined(separator: ",")
            return try SQLite.rows(
                db,
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- ids are mailbox row numbers (Int64); every other value is bound
                """
                SELECT a.address FROM messages m JOIN addresses a ON a.ROWID = m.sender
                WHERE m.mailbox IN (\(ids)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids)))
                GROUP BY a.address ORDER BY COUNT(*) DESC LIMIT 1
                """
            ).first?[0].text
        }
    }

    static func looksSent(_ name: String) -> Bool {
        ["sent", "sent items", "sent messages", "sent mail"].contains(name.lowercased())
    }

    // MARK: finding

    private static let columns = """
        m.ROWID, m.mailbox, a.address, a.comment, m.subject_prefix, s.subject, m.date_received, m.read, m.flagged,
        m.size, m.conversation_id, EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)
        FROM messages m LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
        """

    /// Messages matching every filter, newest first.
    func find(_ q: Query, limit: Int, offset: Int) throws -> [Summary] {
        try locked {
            let boxes = try loadMailboxes()
            guard let (condition, bind) = try conditions(q, boxes) else { return [] }
            return try SQLite.rows(
                db,
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- columns and condition are fixed SQL; every value is bound
                "SELECT \(Self.columns) WHERE \(condition) ORDER BY m.date_received DESC, m.ROWID DESC LIMIT ? OFFSET ?",
                bind: bind + [.int(Int64(limit)), .int(Int64(offset))]
            ).map { try summary($0, boxes) }
        }
    }

    /// One batch of candidates for the text search, newest first, before `before` (a row's
    /// date and id, so equal dates don't repeat or skip).
    func candidates(_ q: Query, after cursor: (Date, Int64)?, limit: Int) throws -> [Summary] {
        try locked {
            let boxes = try loadMailboxes()
            guard var (condition, bind) = try conditions(q, boxes) else { return [] }
            if let (date, id) = cursor {
                condition += " AND (m.date_received < ? OR (m.date_received = ? AND m.ROWID < ?))"
                let t = Int64(date.timeIntervalSince1970)
                bind += [.int(t), .int(t), .int(id)]
            }
            return try SQLite.rows(
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- columns and condition are fixed SQL; every value is bound
                db, "SELECT \(Self.columns) WHERE \(condition) ORDER BY m.date_received DESC, m.ROWID DESC LIMIT ?",
                bind: bind + [.int(Int64(limit))]
            ).map { try summary($0, boxes) }
        }
    }

    /// Mailboxes named `name` (the last part of their path, any case; "Inbox" also matches
    /// Gmail's "INBOX"), in the given accounts.
    func mailboxes(named name: String, accounts: [String]?) throws -> [Mailbox] {
        try locked { Self.named(name, in: try loadMailboxes(), accounts: accounts) }
    }

    private static func named(_ name: String, in boxes: [Mailbox], accounts: [String]?) -> [Mailbox] {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return boxes.filter { b in
            (accounts.map { $0.contains(b.accountID) } ?? true)
                && (b.name.caseInsensitiveCompare(wanted) == .orderedSame
                    || b.path.caseInsensitiveCompare(wanted) == .orderedSame
                    || (wanted.lowercased() == "sent" && looksSent(b.name)))
        }
    }

    private func conditions(_ q: Query, _ boxes: [Mailbox]) throws -> (String, [SQLite.Value])? {
        var c = ["m.deleted = 0"]
        var bind: [SQLite.Value] = []
        func like(_ s: String) -> SQLite.Value {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return .text("%\(escaped)%")
        }
        if let f = q.from?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            c.append("(a.address LIKE ? ESCAPE '\\' OR a.comment LIKE ? ESCAPE '\\')")
            bind += [like(f), like(f)]
        }
        if let t = q.to?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            c.append(
                """
                m.ROWID IN (SELECT r.message FROM recipients r JOIN addresses ra ON ra.ROWID = r.address
                  WHERE ra.address LIKE ? ESCAPE '\\' OR ra.comment LIKE ? ESCAPE '\\')
                """)
            bind += [like(t), like(t)]
        }
        if let s = q.subject?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            c.append("s.subject LIKE ? ESCAPE '\\'")
            bind.append(like(s))
        }
        var scope: [Mailbox]?
        if let accounts = q.accounts { scope = boxes.filter { accounts.contains($0.accountID) } }
        if let name = q.mailbox?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            scope = Self.named(name, in: boxes, accounts: q.accounts)
        }
        if let scope {
            guard !scope.isEmpty else { return nil }
            let ids = scope.map { String($0.rowid) }.joined(separator: ",")
            c.append(
                "(m.mailbox IN (\(ids)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids))))")
        }
        if let d = q.since {
            c.append("m.date_received >= ?")
            bind.append(.int(Int64(d.timeIntervalSince1970.rounded(.down))))
        }
        if let d = q.until {
            c.append("m.date_received < ?")
            bind.append(.int(Int64(d.timeIntervalSince1970.rounded(.up))))
        }
        if let u = q.unread { c.append(u ? "m.read = 0" : "m.read != 0") }
        if let f = q.flagged { c.append(f ? "m.flagged != 0" : "m.flagged = 0") }
        if let a = q.hasAttachments {
            c.append((a ? "" : "NOT ") + "EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)")
        }
        return (c.joined(separator: " AND "), bind)
    }

    private func summary(_ r: [SQLite.Value], _ boxes: [Mailbox]) throws -> Summary {
        let id = r[0].int ?? 0
        let box =
            boxes.first { $0.rowid == r[1].int }
            ?? Mailbox(rowid: r[1].int ?? 0, url: "", accountID: "", path: "?", total: 0, unread: 0)
        var labels: [Mailbox] = []
        if boxes.contains(where: { $0.source == box.rowid }) {
            let ids = try SQLite.rows(db, "SELECT mailbox_id FROM labels WHERE message_id = ?", bind: [.int(id)])
                .compactMap { $0[0].int }
            labels = boxes.filter { ids.contains($0.rowid) && $0.rowid != box.rowid }
                .sorted { a, _ in a.name.uppercased() == "INBOX" }
        }
        return Summary(
            id: id, mailbox: box, labels: labels, senderAddress: r[2].text ?? "", senderName: r[3].text ?? "",
            subject: (r[4].text ?? "") + (r[5].text ?? ""),
            date: Date(timeIntervalSince1970: Double(r[6].int ?? 0)), unread: r[7].int == 0,
            flagged: (r[8].int ?? 0) != 0,
            hasAttachments: r[11].int == 1, size: Int(r[9].int ?? 0), conversation: r[10].int ?? 0)
    }

    func message(_ id: Int64) throws -> Summary {
        try locked {
            let boxes = try loadMailboxes()
            // nosemgrep: scripts.semgrep.latchkey-sql-bound -- columns and condition are fixed SQL; every value is bound
            guard let r = try SQLite.rows(db, "SELECT \(Self.columns) WHERE m.ROWID = ?", bind: [.int(id)]).first,
                r[0].int != nil
            else { throw Failure.noSuchMessage(id) }
            return try summary(r, boxes)
        }
    }

    func recipients(_ id: Int64) throws -> [Recipient] {
        try locked {
            try SQLite.rows(
                db,
                """
                SELECT r.type, a.address, a.comment FROM recipients r JOIN addresses a ON a.ROWID = r.address
                WHERE r.message = ? ORDER BY r.type, r.position
                """, bind: [.int(id)]
            ).map {
                Recipient(
                    kind: Recipient.Kind(rawValue: Int($0[0].int ?? 0)) ?? .to, address: $0[1].text ?? "",
                    name: $0[2].text ?? "")
            }
        }
    }

    /// The other messages of its conversation, newest first.
    func conversation(of id: Int64, limit: Int) throws -> [Summary] {
        let m = try message(id)
        guard m.conversation != 0 else { return [m] }
        return try locked {
            let boxes = try loadMailboxes()
            return try SQLite.rows(
                db,
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- columns and condition are fixed SQL; every value is bound
                "SELECT \(Self.columns) WHERE m.conversation_id = ? AND m.deleted = 0 ORDER BY m.date_received DESC LIMIT ?",
                bind: [.int(m.conversation), .int(Int64(limit))]
            ).map { try summary($0, boxes) }
        }
    }

    func messageIDHeader(_ id: Int64) throws -> String? {
        try locked {
            try SQLite.rows(
                db,
                "SELECT g.message_id_header FROM messages m JOIN message_global_data g ON g.ROWID = m.global_message_id WHERE m.ROWID = ?",
                bind: [.int(id)]
            ).first?[0].text
        }
    }

    /// How many messages (not deleted) carry this Message-ID, with or without its angle brackets,
    /// in any letter case. Mail's `message://` link opens one of them, and anyone can send a
    /// message with a copied Message-ID (security review 2026-10-30).
    func messagesSharing(messageID: String) throws -> Int {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return try locked {
            Int(
                try SQLite.rows(
                    db,
                    """
                    SELECT COUNT(*) FROM messages m JOIN message_global_data g ON g.ROWID = m.global_message_id
                    WHERE m.deleted = 0 AND (g.message_id_header = ? COLLATE NOCASE OR g.message_id_header = ? COLLATE NOCASE)
                    """, bind: [.text("<\(bare)>"), .text(bare)]
                ).first?[0].int ?? 0)
        }
    }

    /// A message just sent: in one of `mailboxes` (or listed there by a label), received at or
    /// after `since`, with this subject (ignoring Mail's "Re:"/"Fwd:") and a recipient with
    /// this address (plan D7).
    func sentCopy(in mailboxes: [Mailbox], since: Date, subject: String, recipient: String) throws -> (
        id: Int64, messageID: String?, attachments: Int
    )? {
        guard !mailboxes.isEmpty else { return nil }
        return try locked {
            let ids = mailboxes.map { String($0.rowid) }.joined(separator: ",")
            let rows = try SQLite.rows(
                db,
                // nosemgrep: scripts.semgrep.latchkey-sql-bound -- ids are mailbox row numbers (Int64); every other value is bound
                """
                SELECT m.ROWID, s.subject, g.message_id_header,
                  (SELECT COUNT(*) FROM attachments t WHERE t.message = m.ROWID)
                FROM messages m LEFT JOIN subjects s ON s.ROWID = m.subject
                  LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
                WHERE m.date_received >= ? AND (m.mailbox IN (\(ids))
                  OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids))))
                  AND m.ROWID IN (SELECT r.message FROM recipients r JOIN addresses ra ON ra.ROWID = r.address
                    WHERE ra.address = ? COLLATE NOCASE)
                ORDER BY m.ROWID DESC
                """, bind: [.int(Int64(since.timeIntervalSince1970.rounded(.down))), .text(recipient)])
            let wanted = Self.bareSubject(subject)
            guard let r = rows.first(where: { Self.bareSubject($0[1].text ?? "") == wanted }) else { return nil }
            return (r[0].int ?? 0, r[2].text, Int(r[3].int ?? 0))
        }
    }

    static func bareSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let r = t.range(of: #"^(re|fwd?|aw|sv|vs)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.lowercased()
    }

    // MARK: message files

    /// The message's file, `.emlx` or `.partial.emlx`; nil when it isn't on the Mac.
    func file(for m: Summary) -> URL? {
        let fm = FileManager.default
        var mbox = root.appending(path: m.mailbox.accountID)
        for part in m.mailbox.path.split(separator: "/") { mbox = mbox.appending(path: "\(part).mbox") }
        let digits = String(m.id / 1000).reversed().map(String.init)
        var stores = [storeUUID]
        stores += ((try? fm.contentsOfDirectory(atPath: mbox.path)) ?? []).filter {
            $0 != storeUUID && !$0.contains(".")
        }
        for store in stores where !store.isEmpty {
            var dir = mbox.appending(path: store).appending(path: "Data")
            if m.id >= 1000 { for d in digits { dir = dir.appending(path: d) } }
            dir = dir.appending(path: "Messages")
            for name in ["\(m.id).emlx", "\(m.id).partial.emlx"] {
                let f = dir.appending(path: name)
                if fm.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }

    /// The index's attachment rows of a message: Mail's part id (the folder its downloaded copy
    /// is in) and the name.
    func attachmentParts(_ id: Int64) throws -> [(part: String, name: String)] {
        try locked {
            try SQLite.rows(db, "SELECT attachment_id, name FROM attachments WHERE message = ?", bind: [.int(id)])
                .compactMap { r in r[0].text.map { ($0, r[1].text ?? "") } }
        }
    }

    /// Where Mail keeps a partial message's downloaded attachments.
    func attachmentsFolder(for file: URL, id: Int64) -> URL {
        file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Attachments/\(id)")
    }
}
