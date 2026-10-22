import Foundation
import SQLite3
import zlib

@testable import Latchkey

/// Builds a small NoteStore.sqlite in the layout Notes uses (one table for notes, folders,
/// attachments, and media, told apart by Z_ENT; bodies gzip-compressed protobuf), so the reader
/// can be tested without anyone's real notes.
enum NotesFixture {
    struct Run {
        var length: Int
        var style: Int? = nil
        var done: Bool? = nil
        var indent: Int = 0
        var attachment: (id: String, uti: String)? = nil
    }

    // MARK: protobuf and gzip, the encoding side of NoteBody

    static func varint(_ v: UInt64) -> Data {
        var v = v
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func field(_ n: Int, varint v: UInt64) -> Data { varint(UInt64(n << 3)) + varint(v) }

    static func field(_ n: Int, bytes: Data) -> Data {
        varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    static func body(_ text: String, runs: [Run]) -> Data {
        var note = field(2, bytes: Data(text.utf8))
        for r in runs {
            var run = field(1, varint: UInt64(r.length))
            if r.style != nil || r.done != nil || r.indent > 0 {
                var ps = Data()
                if let style = r.style { ps += field(1, varint: UInt64(style)) }
                if r.indent > 0 { ps += field(4, varint: UInt64(r.indent)) }
                if let done = r.done {
                    ps += field(
                        5, bytes: field(1, bytes: Data(UUID().uuidString.utf8)) + field(2, varint: done ? 1 : 0))
                }
                run += field(2, bytes: ps)
            }
            if let a = r.attachment {
                run += field(12, bytes: field(1, bytes: Data(a.id.utf8)) + field(2, bytes: Data(a.uti.utf8)))
            }
            note += field(5, bytes: run)
        }
        let document = field(2, varint: 0) + field(3, bytes: note)
        return gzip(field(2, bytes: document))
    }

    static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        var out = Data(count: data.count + 1024)
        var input = data
        let written = input.withUnsafeMutableBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                stream.next_in = inBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(data.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuf.count)
                deflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        deflateEnd(&stream)
        return out.prefix(written)
    }

    // MARK: the database

    /// Core Data timestamps count seconds from 2001-01-01.
    static func coreData(_ d: Date) -> Double { d.timeIntervalSinceReferenceDate }

    static let modified = Date(timeIntervalSince1970: 1_790_000_000)

    /// Creates the fixture in a temporary folder and returns the database URL.
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        let media = dir.appending(path: "Accounts/ACCOUNT-1/Media/MEDIA-1/1_ABC")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try pngPixel.write(to: media.appending(path: "photo.png"))
        let url = dir.appending(path: "NoteStore.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        exec(
            """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES (5,'ICAttachment',0,0),(9,'ICFolder',0,0),(11,'ICMedia',0,0),(12,'ICNote',0,0);
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR,
              ZTITLE1 VARCHAR, ZTITLE2 VARCHAR, ZSNIPPET VARCHAR, ZFOLDER INTEGER, ZNOTEDATA INTEGER,
              ZCREATIONDATE3 TIMESTAMP, ZMODIFICATIONDATE1 TIMESTAMP, ZMARKEDFORDELETION INTEGER,
              ZISPASSWORDPROTECTED INTEGER, ZFOLDERTYPE INTEGER, ZNOTE INTEGER, ZTYPEUTI VARCHAR,
              ZMEDIA INTEGER, ZFILENAME VARCHAR);
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB, ZNOTE INTEGER);
            """)
        let t = coreData(modified)
        exec(
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE2,ZFOLDERTYPE) VALUES
              (1,9,'F-NOTES','Notes',0),(2,9,'F-TRIPS','Trips',0),(3,9,'F-TRASH','Recently Deleted',1);
            INSERT INTO ZICCLOUDSYNCINGOBJECT
              (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZSNIPPET,ZFOLDER,ZNOTEDATA,ZCREATIONDATE3,ZMODIFICATIONDATE1,ZISPASSWORDPROTECTED)
            VALUES
              (10,12,'N-GROCERIES','Groceries','Milk',1,100,\(t - 86400),\(t),0),
              (11,12,'N-LISBON','Lisbon trip','Flights booked',2,101,\(t - 864000),\(t - 3600),0),
              (12,12,'N-SECRET','Bank codes','',1,102,\(t),\(t),1),
              (13,12,'N-OLD','Old draft','gone',3,103,\(t),\(t),0);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZMEDIA) VALUES
              (20,5,'A-PHOTO',11,'public.png',21);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZFILENAME) VALUES (21,11,'MEDIA-1','photo.png');
            """)
        let groceries = "Groceries\nMilk\nBread\nShop on Saturday"
        let lisbon = "Lisbon trip\nFlights\nFlights booked for May 3\n\u{FFFC}\nHotel near Alfama"
        let bodies: [(Int, Data)] = [
            (
                100,
                body(
                    groceries,
                    runs: [
                        Run(length: 10, style: 0), Run(length: 5, style: 103, done: true),
                        Run(length: 6, style: 103, done: false), Run(length: 16),
                    ])
            ),
            (
                101,
                body(
                    lisbon,
                    runs: [
                        Run(length: 12, style: 0), Run(length: 8, style: 1), Run(length: 25, style: 100),
                        Run(length: 1, attachment: ("A-PHOTO", "public.png")), Run(length: 18),
                    ])
            ),
            (102, Data()),
            (103, body("Old draft\ngone", runs: [Run(length: 14)])),
        ]
        for (pk, data) in bodies {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ZICNOTEDATA (Z_PK, ZDATA) VALUES (?, ?)", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(pk))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), nil) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return url
    }

    /// A 1×1 PNG.
    static let pngPixel = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
}
