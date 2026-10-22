import Foundation
import zlib

/// A note's body, decoded from the gzip-compressed protobuf Notes stores in `ZICNOTEDATA.ZDATA`
/// (spec 002 research "Apple Notes"): the text, plus runs that give each stretch its paragraph
/// style and mark attachments (U+FFFC). Rendered as Markdown-like text (plan D1).
struct NoteBody: Sendable, Equatable {
    struct Attachment: Sendable, Equatable, Codable {
        var id: String
        var uti: String

        var isImage: Bool {
            [
                "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif",
                "public.image",
            ]
            .contains(uti) || uti.hasPrefix("public.") && uti.hasSuffix("image")
        }
    }

    var markdown: String
    var plainText: String
    var attachments: [Attachment]
    var hasChecklists = false

    enum Failure: Error { case notGzip, badProtobuf }

    static func decode(_ data: Data) throws -> NoteBody {
        let raw = try gunzip(data)
        guard let document = try ProtoReader.fields(raw).first(where: { $0.number == 2 })?.bytes,
            let note = try ProtoReader.fields(document).first(where: { $0.number == 3 })?.bytes
        else { throw Failure.badProtobuf }
        var text = ""
        var runs: [Run] = []
        for f in try ProtoReader.fields(note) {
            if f.number == 2, let b = f.bytes { text = String(decoding: b, as: UTF8.self) }
            if f.number == 5, let b = f.bytes { runs.append(try Run(b)) }
        }
        return render(text, runs)
    }

    // MARK: rendering

    private struct Run {
        var length = 0
        var style: Int?
        var indent = 0
        var done: Bool?
        var attachment: Attachment?

        init(_ data: Data) throws {
            for f in try ProtoReader.fields(data) {
                switch f.number {
                case 1: length = Int(f.varint ?? 0)
                case 2:
                    for p in try ProtoReader.fields(f.bytes ?? Data()) {
                        switch p.number {
                        case 1: style = Int(p.varint ?? 0)
                        case 4: indent = Int(p.varint ?? 0)
                        case 5:
                            done = try ProtoReader.fields(p.bytes ?? Data()).first { $0.number == 2 }?.varint == 1
                        default: break
                        }
                    }
                case 12:
                    var id = ""
                    var uti = ""
                    for a in try ProtoReader.fields(f.bytes ?? Data()) {
                        if a.number == 1, let b = a.bytes { id = String(decoding: b, as: UTF8.self) }
                        if a.number == 2, let b = a.bytes { uti = String(decoding: b, as: UTF8.self) }
                    }
                    attachment = Attachment(id: id, uti: uti)
                default: break
                }
            }
        }
    }

    private static let objectReplacement: UInt16 = 0xFFFC

    private static func render(_ text: String, _ runs: [Run]) -> NoteBody {
        let units = Array(text.utf16)
        // The run covering each UTF-16 position (Notes measures runs in UTF-16 units).
        var runAt = [Int](repeating: -1, count: units.count)
        var pos = 0
        for (i, r) in runs.enumerated() {
            for j in pos..<min(pos + r.length, units.count) { runAt[j] = i }
            pos += r.length
        }
        var lines: [String] = []
        var attachments: [Attachment] = []
        var number = 0
        var start = 0
        while start <= units.count {
            let end = units[start...].firstIndex(of: 0x0A) ?? units.count
            let run = start < units.count && runAt[start] >= 0 ? runs[runAt[start]] : nil
            var line = ""
            var chunk: [UInt16] = []
            for j in start..<end {
                if units[j] == objectReplacement, runAt[j] >= 0, let a = runs[runAt[j]].attachment {
                    line += String(decoding: chunk, as: UTF16.self)
                    chunk = []
                    attachments.append(a)
                    line += a.isImage ? "[image \(a.id)]" : "[attachment \(a.id) (\(a.uti))]"
                } else if units[j] != objectReplacement {
                    chunk.append(units[j])
                }
            }
            line += String(decoding: chunk, as: UTF16.self)
            let indent = String(repeating: "  ", count: run?.indent ?? 0)
            number = run?.style == 102 ? number + 1 : 0
            switch run?.style {
            case 0: line = "# " + line
            case 1: line = "## " + line
            case 2: line = "### " + line
            case 100, 101: line = indent + "- " + line
            case 102: line = indent + "\(number). " + line
            case 103: line = indent + (run?.done == true ? "- [x] " : "- [ ] ") + line
            default: break
            }
            lines.append(line)
            if end == units.count { break }
            start = end + 1
        }
        let plain = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        return NoteBody(
            markdown: lines.joined(separator: "\n"), plainText: plain, attachments: attachments,
            hasChecklists: runs.contains { $0.style == 103 })
    }

    // MARK: gzip

    static func gunzip(_ data: Data) throws -> Data {
        guard data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            throw Failure.notGzip
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.notGzip
        }
        defer { inflateEnd(&stream) }
        var out = Data()
        var input = data
        var status = Z_OK
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        input.withUnsafeMutableBytes { inBuf in
            stream.next_in = inBuf.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inBuf.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    out.append(outBuf.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw Failure.notGzip }
        return out
    }
}

/// Just enough protobuf to walk Notes' messages: fields with their number and value.
enum ProtoReader {
    struct Field {
        var number: Int
        var varint: UInt64?
        var bytes: Data?
    }

    static func fields(_ data: Data) throws -> [Field] {
        let b = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func readVarint() throws -> UInt64 {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]
                i += 1
                v |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { break }
            }
            throw NoteBody.Failure.badProtobuf
        }
        while i < b.count {
            let key = try readVarint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: out.append(Field(number: number, varint: try readVarint()))
            case 1: i += 8
            case 2:
                let n = Int(try readVarint())
                guard n >= 0, i + n <= b.count else { throw NoteBody.Failure.badProtobuf }
                out.append(Field(number: number, bytes: Data(b[i..<i + n])))
                i += n
            case 5: i += 4
            default: throw NoteBody.Failure.badProtobuf
            }
            guard i <= b.count else { throw NoteBody.Failure.badProtobuf }
        }
        return out
    }
}
