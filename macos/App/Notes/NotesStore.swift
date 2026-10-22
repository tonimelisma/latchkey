import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Reads Notes' own database, read-only (plan D2). Notes, folders, attachments, and media share one
/// table told apart by entity number; column names differ between macOS versions, so both are
/// looked up when the store opens.
final class NotesStore: @unchecked Sendable {
    struct Folder: Sendable, Equatable {
        var id: String
        var name: String
        var noteCount: Int
    }

    struct Summary: Sendable, Equatable {
        var id: String
        var title: String
        var folder: String
        var modified: Date
        var snippet: String
        var locked: Bool
    }

    struct Note: Sendable, Equatable {
        var id: String
        var title: String
        var folder: String
        var created: Date?
        var modified: Date
        var locked: Bool
        var text: String
        var attachments: [NoteBody.Attachment]
    }

    enum Failure: Error, Equatable {
        case cannotOpen(String)
        case unknownLayout(String)
        case noSuchNote(String)
        case noSuchAttachment(String)
        case notAnImage(String)
    }

    private let db: OpaquePointer
    private let folderURL: URL
    private let lock = NSLock()
    private let ent: (note: Int, folder: Int, attachment: Int, media: Int)
    private let col: Columns
    /// Decoded bodies by note row, kept while the note's modification date is unchanged.
    private var bodies: [Int64: (modified: Double, body: NoteBody?)] = [:]

    private struct Columns {
        var noteTitle: String
        var folderTitle: String
        var created: String?
        var modified: String
        var snippet: String?
        var noteData: String?
        var deleted: String?
        var locked: String?
        var folderType: String?
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        let uri = "file:\(url.path(percentEncoded: true))?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle
        else {
            sqlite3_close(handle)
            throw Failure.cannotOpen(url.path)
        }
        sqlite3_busy_timeout(handle, 2_000)
        db = handle
        folderURL = url.deletingLastPathComponent()
        do {
            var entities: [String: Int] = [:]
            for row in try Self.rows(handle, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY") {
                entities[row[0].text ?? ""] = Int(row[1].int ?? 0)
            }
            guard let n = entities["ICNote"], let f = entities["ICFolder"] else {
                throw Failure.unknownLayout("no note or folder entities")
            }
            ent = (n, f, entities["ICAttachment"] ?? -1, entities["ICMedia"] ?? -1)
            let names = Set(
                try Self.rows(handle, "PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)").compactMap { $0[1].text })
            func first(_ candidates: String...) -> String? { candidates.first { names.contains($0) } }
            guard let noteTitle = first("ZTITLE1", "ZTITLE"), let folderTitle = first("ZTITLE2", "ZTITLE"),
                let modified = first("ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"), names.contains("ZFOLDER")
            else { throw Failure.unknownLayout("missing title, date, or folder columns") }
            col = Columns(
                noteTitle: noteTitle, folderTitle: folderTitle,
                created: first("ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"), modified: modified,
                snippet: first("ZSNIPPET"), noteData: first("ZNOTEDATA"), deleted: first("ZMARKEDFORDELETION"),
                locked: first("ZISPASSWORDPROTECTED"), folderType: first("ZFOLDERTYPE"))
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: queries

    /// Folders that hold notes, without Recently Deleted.
    func folders() throws -> [Folder] {
        try locked {
            let sql = """
                SELECT f.ZIDENTIFIER, f.\(col.folderTitle),
                  (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n WHERE n.Z_ENT = \(ent.note) AND n.ZFOLDER = f.Z_PK
                   AND \(liveNote("n")))
                FROM ZICCLOUDSYNCINGOBJECT f
                WHERE f.Z_ENT = \(ent.folder) AND \(liveFolder("f"))
                ORDER BY f.\(col.folderTitle) COLLATE NOCASE
                """
            return try Self.rows(db, sql).map {
                Folder(id: $0[0].text ?? "", name: $0[1].text ?? "", noteCount: Int($0[2].int ?? 0))
            }
        }
    }

    /// Notes whose title or text contains `query` (all notes, newest first, when it is empty).
    func search(_ query: String, folder: String?, limit: Int) throws -> [Summary] {
        try locked {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var out: [Summary] = []
            for row in try noteRows(where: "1", folder: folder) {
                if out.count >= limit { break }
                let title = row.title
                if q.isEmpty {
                    out.append(row.summary(snippet: row.snippet))
                } else if title.localizedCaseInsensitiveContains(q) {
                    out.append(row.summary(snippet: row.snippet))
                } else if !row.locked, let body = body(row),
                    let range = body.plainText.range(
                        of: q, options: [.caseInsensitive, .diacriticInsensitive])
                {
                    out.append(row.summary(snippet: Self.snippet(body.plainText, around: range)))
                }
            }
            return out
        }
    }

    func read(id: String) throws -> Note {
        try locked {
            guard let row = try noteRows(where: "n.ZIDENTIFIER = ?", folder: nil, bind: [id]).first else {
                throw Failure.noSuchNote(id)
            }
            let body = row.locked ? nil : body(row)
            return Note(
                id: row.id, title: row.title, folder: row.folder, created: row.created, modified: row.modified,
                locked: row.locked, text: body?.markdown ?? "", attachments: body?.attachments ?? [])
        }
    }

    struct Image: Sendable {
        var data: Data
        var mimeType: String
    }

    /// The longest side Claude reads images at; larger ones are scaled down.
    static let maxImageSide = 1568

    /// An image attached to a note, as JPEG or PNG, scaled down if large (FR-104).
    func image(note: String, attachment: String) throws -> Image {
        let file: URL = try locked {
            let sql = """
                SELECT m.ZIDENTIFIER, m.ZFILENAME FROM ZICCLOUDSYNCINGOBJECT a
                JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = a.ZNOTE AND n.Z_ENT = \(ent.note)
                LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = a.ZMEDIA AND m.Z_ENT = \(ent.media)
                WHERE a.Z_ENT = \(ent.attachment) AND a.ZIDENTIFIER = ? AND n.ZIDENTIFIER = ?
                """
            guard let row = try Self.rows(db, sql, bind: [attachment, note]).first else {
                throw Failure.noSuchAttachment(attachment)
            }
            guard let mediaID = row[0].text, let file = mediaFile(mediaID, name: row[1].text) else {
                throw Failure.notAnImage(attachment)
            }
            return file
        }
        return try Self.prepareImage(file)
    }

    // MARK: helpers

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func liveNote(_ n: String) -> String {
        var parts = [
            "\(n).ZFOLDER IN (SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = \(ent.folder) AND \(liveFolder("")))"
        ]
        if let d = col.deleted { parts.append("COALESCE(\(n).\(d), 0) = 0") }
        return parts.joined(separator: " AND ")
    }

    private func liveFolder(_ f: String) -> String {
        let p = f.isEmpty ? "" : "\(f)."
        var parts: [String] = []
        if let t = col.folderType { parts.append("COALESCE(\(p)\(t), 0) <> 1") }  // 1 is Recently Deleted
        if let d = col.deleted { parts.append("COALESCE(\(p)\(d), 0) = 0") }
        return parts.isEmpty ? "1" : parts.joined(separator: " AND ")
    }

    private struct NoteRow {
        var pk: Int64
        var id: String
        var title: String
        var folder: String
        var created: Date?
        var modified: Date
        var modifiedRaw: Double
        var snippet: String
        var locked: Bool
        var data: Data?

        func summary(snippet: String) -> Summary {
            Summary(id: id, title: title, folder: folder, modified: modified, snippet: snippet, locked: locked)
        }
    }

    private func noteRows(where condition: String, folder: String?, bind: [String] = []) throws -> [NoteRow] {
        let dataJoin =
            col.noteData.map { "LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.\($0)" }
            ?? "LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK"
        var bind = bind
        var folderFilter = ""
        if let folder {
            folderFilter = "AND f.\(col.folderTitle) = ? COLLATE NOCASE"
            bind.append(folder)
        }
        let sql = """
            SELECT n.Z_PK, n.ZIDENTIFIER, n.\(col.noteTitle), f.\(col.folderTitle),
              \(col.created.map { "n.\($0)" } ?? "NULL"), n.\(col.modified),
              \(col.snippet.map { "n.\($0)" } ?? "''"), \(col.locked.map { "n.\($0)" } ?? "0"), d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT n
            JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            \(dataJoin)
            WHERE n.Z_ENT = \(ent.note) AND \(liveNote("n")) AND \(condition) \(folderFilter)
            ORDER BY n.\(col.modified) DESC, n.Z_PK
            """
        return try Self.rows(db, sql, bind: bind).map { r in
            let modified = r[5].double ?? 0
            return NoteRow(
                pk: r[0].int ?? 0, id: r[1].text ?? "", title: r[2].text ?? "Untitled", folder: r[3].text ?? "",
                created: r[4].double.map(Date.init(timeIntervalSinceReferenceDate:)),
                modified: Date(timeIntervalSinceReferenceDate: modified), modifiedRaw: modified,
                snippet: r[6].text ?? "", locked: (r[7].int ?? 0) != 0, data: r[8].blob)
        }
    }

    private func body(_ row: NoteRow) -> NoteBody? {
        if let cached = bodies[row.pk], cached.modified == row.modifiedRaw { return cached.body }
        let body = row.data.flatMap { try? NoteBody.decode($0) }
        bodies[row.pk] = (row.modifiedRaw, body)
        return body
    }

    static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.lowerBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
        let s = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " · ")
        return (start > text.startIndex ? "…" : "") + s + (end < text.endIndex ? "…" : "")
    }

    /// Media live under `Accounts/<account>/Media/<media id>/…/<file name>`.
    private func mediaFile(_ mediaID: String, name: String?) -> URL? {
        let accounts = folderURL.appending(path: "Accounts")
        let fm = FileManager.default
        for account in (try? fm.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? [] {
            let dir = account.appending(path: "Media/\(mediaID)")
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            var found: URL?
            for case let file as URL in walker
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if name == nil || file.lastPathComponent == name { return file }
                found = found ?? file
            }
            if let found { return found }
        }
        return nil
    }

    /// JPEG and PNG under the size limit go as they are; anything else (HEIC, large photos) becomes
    /// a JPEG no larger than `maxImageSide`.
    static func prepareImage(_ file: URL) throws -> Image {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let type = CGImageSourceGetType(source) as String?
        else { throw Failure.notAnImage(file.lastPathComponent) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let side = max(
            props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if side > 0, side <= maxImageSide, size < 3_000_000,
            let mime = [UTType.jpeg.identifier: "image/jpeg", UTType.png.identifier: "image/png"][type],
            let data = try? Data(contentsOf: file)
        {
            return Image(data: data, mimeType: mime)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.notAnImage(file.lastPathComponent)
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.notAnImage(file.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.notAnImage(file.lastPathComponent) }
        return Image(data: out as Data, mimeType: "image/jpeg")
    }

    // MARK: SQLite

    enum Value {
        case null, int(Int64), double(Double), text(String), blob(Data)

        var int: Int64? {
            switch self {
            case .int(let i): i
            case .double(let d): Int64(d)
            default: nil
            }
        }
        var double: Double? {
            switch self {
            case .double(let d): d
            case .int(let i): Double(i)
            default: nil
            }
        }
        var text: String? { if case .text(let s) = self { s } else { nil } }
        var blob: Data? { if case .blob(let b) = self { b } else { nil } }
    }

    static func rows(_ db: OpaquePointer, _ sql: String, bind: [String] = []) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.unknownLayout(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, s) in bind.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient) }
        var out: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.unknownLayout(String(cString: sqlite3_errmsg(db))) }
            out.append(
                (0..<sqlite3_column_count(stmt)).map { c in
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, c))
                    case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, c)))
                    case SQLITE_BLOB:
                        .blob(
                            sqlite3_column_bytes(stmt, c) > 0
                                ? Data(bytes: sqlite3_column_blob(stmt, c), count: Int(sqlite3_column_bytes(stmt, c)))
                                : Data())
                    default: .null
                    }
                })
        }
        return out
    }
}
