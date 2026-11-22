import AppKit
import Foundation

/// Apple Mail on this Mac, for Claude's Mail tools (spec 008 FR-850 to FR-853; Toni, 2026-11-22:
/// "Claude reads Apple Mail", for when Claude has no email tool of its own): Mail's own index and
/// email files are read, never its window; Mail is started hidden when it isn't running, so new
/// mail arrives; an email is marked read and archived through Mail's scripting while unlocked.
enum MailCodes {
    static let bundleID = Permissions.mailApp

    /// Mail's index: the newest `V<n>` folder's (Mail moves to a new one with major versions).
    static var index: URL? {
        let mail = URL.homeDirectory.appending(path: "Library/Mail")
        let versions =
            ((try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? [])
            .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .sorted { Int($0.dropFirst())! > Int($1.dropFirst())! }
        guard let v = versions.first else { return nil }
        let url = mail.appending(path: "\(v)/MailData/Envelope Index")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// An email's place, for archiving it: Mail's id, its account's id, and its mailbox's name.
    struct Place: Equatable, Sendable {
        var id: Int64
        var account: String
        var mailbox: String

        /// "mail:" then the three, tab-separated (an id in `TextedCodes`' list).
        var key: String { "mail:\(id)\t\(account)\t\(mailbox)" }

        init(id: Int64, account: String, mailbox: String) {
            self.id = id
            self.account = account
            self.mailbox = mailbox
        }

        init?(key: String) {
            guard key.hasPrefix("mail:") else { return nil }
            let parts = key.dropFirst(5).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let id = Int64(parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            self.init(id: id, account: parts[1], mailbox: parts[2])
        }

        /// From a mailbox address in Mail's index ("ews://<account>/Inbox", "imap://<account>/INBOX").
        init?(id: Int64, url: String) {
            guard let u = URL(string: url), let account = u.host(), !account.isEmpty else { return nil }
            let path = u.path(percentEncoded: false)
            let mailbox = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !mailbox.isEmpty else { return nil }
            self.init(id: id, account: account, mailbox: mailbox)
        }
    }

    /// Whether an email's text names `site`: its registered name's first part ("github" for
    /// github.com) when that is 3 letters or more, else the whole registered name, as a whole word
    /// (security review 2026-11-21: an email's code is taken only from an email about that site;
    /// 2026-11-22: "citi" isn't named by "capacities", nor "app" by "apple").
    static func names(_ site: String, in text: String) -> Bool {
        let registered = PublicSuffix.registrable(site).lowercased()
        let brand = String(registered.split(separator: ".").first ?? "")
        let word = brand.count >= 3 ? brand : registered
        guard !word.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    /// Mailboxes the Mail tools leave out: what the Owner sent or drafted, and what's deleted.
    static func skipped(_ mailbox: String) -> Bool {
        let m = mailbox.lowercased()
        return ["sent", "draft", "deleted", "trash", "outbox"].contains { m.contains($0) }
    }

    /// One email as Mail's index knows it.
    struct Email: Sendable, Equatable {
        var place: Place
        var date: Date
        var sender: String
        var subject: String
        var unread: Bool
    }

    private static let select = """
        SELECT m.ROWID, m.date_received, COALESCE(s.subject, ''), mb.url, COALESCE(a.address, ''),
          COALESCE(a.comment, ''), m.read
        FROM messages m LEFT JOIN subjects s ON s.ROWID = m.subject JOIN mailboxes mb ON mb.ROWID = m.mailbox
          LEFT JOIN addresses a ON a.ROWID = m.sender
        """

    private static func email(_ r: [SQLite.Value]) -> Email? {
        guard let id = r[0].int, let place = Place(id: id, url: r[3].text ?? ""), !skipped(place.mailbox) else {
            return nil
        }
        let address = r[4].text ?? "", name = r[5].text ?? ""
        return Email(
            place: place, date: Date(timeIntervalSince1970: Double(r[1].int ?? 0)),
            sender: name.isEmpty || name == address ? address : "\(name) <\(address)>", subject: r[2].text ?? "",
            unread: (r[6].int ?? 1) == 0)
    }

    /// Emails received since `since`, newest first, at most `limit`, optionally only those whose
    /// sender or subject holds the words given; nil when Mail's index can't be read.
    static func find(
        since: Date, from: String = "", subject: String = "", unreadOnly: Bool = false, limit: Int = 30,
        index: URL? = MailCodes.index
    ) -> [Email]? {
        guard let url = index, let db = try? SQLite.openReadOnly(url) else { return nil }
        defer { SQLite.close(db) }
        var sql = select + " WHERE m.date_received >= ? AND m.deleted = 0"
        var bind: [SQLite.Value] = [.int(Int64(since.timeIntervalSince1970))]
        if !from.isEmpty {
            sql += " AND (a.address LIKE ? OR a.comment LIKE ?)"
            bind += [.text("%\(from)%"), .text("%\(from)%")]
        }
        if !subject.isEmpty {
            sql += " AND s.subject LIKE ?"
            bind.append(.text("%\(subject)%"))
        }
        if unreadOnly { sql += " AND m.read = 0" }
        sql += " ORDER BY m.date_received DESC LIMIT ?"
        bind.append(.int(Int64(max(1, min(limit, 100)) * 2)))
        guard let rows = try? SQLite.rows(db, sql, bind: bind) else { return nil }
        return Array(rows.compactMap(email).prefix(limit))
    }

    /// One email by Mail's id; nil when there is none (or it is in a mailbox the tools leave out).
    static func email(id: Int64, index: URL? = MailCodes.index) -> Email? {
        guard let url = index, let db = try? SQLite.openReadOnly(url) else { return nil }
        defer { SQLite.close(db) }
        let rows = try? SQLite.rows(db, select + " WHERE m.ROWID = ? AND m.deleted = 0", bind: [.int(id)])
        return rows?.first.flatMap(email)
    }

    /// The email's text from its file, once Mail has saved it; nil before.
    static func text(of e: Email, index: URL? = MailCodes.index) -> String? {
        guard let url = index else { return nil }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        return file(of: e.place, in: root).flatMap { try? Data(contentsOf: $0) }.map(Self.text(ofEmlx:))
    }

    /// Mail's file for an email: `<account>/<mailbox>.mbox/<store>/Data/<digits>/Messages/<id>.emlx`,
    /// the digits those of id / 1000 in reverse ("106222" → 6/0/1), `.partial.emlx` while its
    /// attachments aren't downloaded. Nil when Mail hasn't saved it yet.
    static func file(of place: Place, in root: URL) -> URL? {
        var box = root.appending(path: place.account, directoryHint: .isDirectory)
        for part in place.mailbox.split(separator: "/") {
            box.append(path: "\(part).mbox", directoryHint: .isDirectory)
        }
        let stores = (try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []
        let digits = String(place.id / 1000).reversed().map(String.init)
        for store in stores where !store.hasSuffix(".mbox") && !store.hasPrefix(".") {
            var dir = box.appending(path: "\(store)/Data", directoryHint: .isDirectory)
            for d in digits where place.id >= 1000 { dir.append(path: d, directoryHint: .isDirectory) }
            dir.append(path: "Messages", directoryHint: .isDirectory)
            for name in ["\(place.id).emlx", "\(place.id).partial.emlx"] {
                let f = dir.appending(path: name)
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }

    /// The readable text of an `.emlx` (a byte count line, then the email): its plain-text parts,
    /// else its HTML parts without tags, styles, or scripts; at most 64 KB looked at.
    static func text(ofEmlx data: Data) -> String {
        var d = data.prefix(1 << 20)
        // The byte count, padded with spaces in Mail's files ("44036     ", 2026-11-21).
        if let nl = d.firstIndex(of: 0x0A),
            d[d.startIndex..<nl].allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x20 || $0 == 0x0D })
        {
            d = d[d.index(after: nl)...]
        }
        let parts = leaves(String(decoding: d, as: UTF8.self))
        let plain = parts.filter { $0.type.hasPrefix("text/plain") }.map(\.body)
        let html = parts.filter { $0.type.hasPrefix("text/html") }.map { strip($0.body) }
        // Both: IKEA's plain text glues the code to the next word ("code.123456Please"), while
        // its HTML keeps it in a cell of its own (2026-11-21).
        return String((plain + html).joined(separator: "\n").prefix(65536))
    }

    /// The email's text parts (type and decoded text), multipart ones opened.
    private static func leaves(_ message: String, depth: Int = 0) -> [(type: String, body: String)] {
        let split = message.range(of: "\r\n\r\n") ?? message.range(of: "\n\n")
        guard let split, depth < 6 else { return [] }
        let head = String(message[..<split.lowerBound]).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        let body = String(message[split.upperBound...])
        func header(_ name: String) -> String {
            head.split(separator: "\n").first { $0.lowercased().hasPrefix(name + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let type = header("content-type").lowercased()
        if type.hasPrefix("multipart/") {
            let full = header("content-type")
            guard let r = full.range(of: "boundary=", options: .caseInsensitive),
                let raw = full[r.upperBound...].split(separator: ";").first
            else { return [] }
            let boundary = "--" + raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return body.components(separatedBy: boundary).dropFirst().flatMap {
                $0.hasPrefix("--") ? [] : leaves(String($0.drop { $0 == "\r" || $0 == "\n" }), depth: depth + 1)
            }
        }
        guard type.isEmpty || type.hasPrefix("text/") else { return [] }
        let encoding = header("content-transfer-encoding").lowercased()
        let text: String =
            if encoding == "base64" {
                Data(base64Encoded: body.filter { !$0.isWhitespace }).map { String(decoding: $0, as: UTF8.self) } ?? ""
            } else if encoding == "quoted-printable" {
                quotedPrintable(body)
            } else {
                body
            }
        return [(type.isEmpty ? "text/plain" : type, text)]
    }

    static func quotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "=") {
                if i + 1 < u.count, u[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < u.count, u[i + 1] == 0x0D, u[i + 2] == 0x0A {
                    i += 3
                    continue
                }
                if i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(v)
                    i += 3
                    continue
                }
            }
            bytes.append(u[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// HTML as text: styles, scripts, and the head go, tags become spaces, common entities decoded.
    static func strip(_ html: String) -> String {
        var s = html
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<script\b.*?</script>"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")]
        {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Starts Mail hidden when it isn't running, so it fetches the code (FR-1365).
    @MainActor
    static func start() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        EventLog.shared.record(.app, "Started Apple Mail in the background for Claude's Mail tools")
    }

    /// Marks the email read and moves it to its account's archive (spec 008 FR-852): "Archive", or Gmail's
    /// "All Mail"; when the account has neither, it is only marked read. Only through Mail's
    /// scripting, never its window, and only while the Mac is unlocked (Mail froze when scripted
    /// behind the lock, 2026-11-02).
    static func archive(_ place: Place, runner: any ScriptRunner = OSAScriptRunner(app: Permissions.mailApp))
        async throws
    {
        let answer = try await runner.run(Script.archive, [place.account, place.mailbox, String(place.id)])
        guard answer.hasPrefix("ok") else {
            throw CodeTextWindow.Problem(message: answer.isEmpty ? "Mail didn't answer" : answer)
        }
    }

    /// The email's text, from Mail's scripting, which downloads a body not yet downloaded; nil
    /// when Mail doesn't have it.
    static func content(
        _ place: Place, runner: any ScriptRunner = OSAScriptRunner(app: Permissions.mailApp, timeout: .seconds(15))
    )
        async throws -> String?
    {
        let answer = try await runner.run(Script.content, [place.account, place.mailbox, String(place.id)])
        return answer.hasPrefix("ok\n") ? String(answer.dropFirst(3)) : nil
    }

    enum Script {
        static let content = """
            on run argv
            set accountID to item 1 of argv
            set boxName to item 2 of argv
            set wantedID to (item 3 of argv) as integer
            tell application "Mail"
            set theAccount to first account whose id is accountID
            set found to (messages of (mailbox boxName of theAccount) whose id is wantedID)
            if (count of found) is 0 then return "none"
            return "ok" & linefeed & (content of item 1 of found)
            end tell
            end run
            """

        static let archive = """
            on run argv
            set accountID to item 1 of argv
            set boxName to item 2 of argv
            set wantedID to (item 3 of argv) as integer
            tell application "Mail"
            set theAccount to first account whose id is accountID
            set theBox to mailbox boxName of theAccount
            set found to (messages of theBox whose id is wantedID)
            if (count of found) is 0 then return "not found"
            set theMessage to item 1 of found
            set read status of theMessage to true
            set archiveBox to missing value
            repeat with boxCandidate in {"Archive", "All Mail", "[Gmail]/All Mail"}
            try
            set archiveBox to mailbox (boxCandidate as text) of theAccount
            exit repeat
            end try
            end repeat
            if archiveBox is missing value then return "ok, marked read (no archive mailbox)"
            if name of archiveBox is name of theBox then return "ok, already archived"
            move theMessage to archiveBox
            return "ok"
            end tell
            end run
            """
    }
}
