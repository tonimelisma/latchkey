import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// What's in a file, for Claude (spec 003 plan D2): text (including the text of PDFs and
/// documents), an image, or nothing readable.
enum FileReader {
    enum Content {
        /// A page of the text, the text's full length, and where the next page starts.
        case text(String, total: Int, next: Int?)
        case image(PreparedImage)
        case notReadable(String)
    }

    /// FR-207: at most this many characters per answer.
    static let pageSize = ResultLimit.characters
    static let maxBytes = 100_000_000

    private struct TooLarge: Error {}

    static func read(_ url: URL, offset: Int) throws -> Content {
        // Type and size of the file actually read: a symbolic link's own size is a few bytes
        // whatever it points to (security scan, 2026-10-24).
        let target = url.resolvingSymlinksInPath()
        let values = try? target.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .fileResourceTypeKey])
        if let kind = values?.fileResourceType, [.namedPipe, .characterSpecial, .blockSpecial, .socket].contains(kind) {
            return .notReadable("not a file but a device or pipe")
        }
        let type = values?.contentType ?? .data
        if type.conforms(to: .image) {
            do { return .image(try ImagePrep.prepare(target)) } catch {
                return .notReadable("an image macOS can't open")
            }
        }
        guard (values?.fileSize ?? 0) <= maxBytes else { return .notReadable("larger than 100 MB") }
        let text: String?
        do { text = try Self.text(of: target, type: type) } catch is TooLarge {
            return .notReadable("larger than 100 MB")
        }
        guard let text else {
            return .notReadable(
                "not text, a PDF, a document, or an image (\(type.localizedDescription ?? type.identifier))")
        }
        let (page, next) = ResultLimit.page(text, offset: offset)
        return .text(page, total: text.count, next: next)
    }

    private static let documentTypes: [UTType] = [
        .rtf, .rtfd, .html, .webArchive, UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    private static func text(of url: URL, type: UTType) throws -> String? {
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { return nil }
            return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        if documentTypes.contains(where: { type.conforms(to: $0) }) {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        let data = try contents(url)
        if data.prefix(8192).contains(0) {
            // UTF-16 text has zero bytes too; it starts with a byte order mark.
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                return String(data: data, encoding: .utf16)
            }
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// The file's bytes, at most `maxBytes`: the size seen before opening may not be what is read.
    private static func contents(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw TooLarge() }
        return data
    }
}
