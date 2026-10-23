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
    static let pageSize = 100_000
    static let maxBytes = 100_000_000

    static func read(_ url: URL, offset: Int) throws -> Content {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        if type.conforms(to: .image) {
            do { return .image(try ImagePrep.prepare(url)) } catch { return .notReadable("an image macOS can't open") }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { return .notReadable("larger than 100 MB") }
        guard let text = try text(of: url, type: type) else {
            return .notReadable(
                "not text, a PDF, a document, or an image (\(type.localizedDescription ?? type.identifier))")
        }
        let total = text.count
        let start = text.index(text.startIndex, offsetBy: min(max(offset, 0), total))
        let end = text.index(start, offsetBy: pageSize, limitedBy: text.endIndex) ?? text.endIndex
        let next = end < text.endIndex ? text.distance(from: text.startIndex, to: end) : nil
        return .text(String(text[start..<end]), total: total, next: next)
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
        let data = try Data(contentsOf: url)
        if data.prefix(8192).contains(0) {
            // UTF-16 text has zero bytes too; it starts with a byte order mark.
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                return String(data: data, encoding: .utf16)
            }
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
