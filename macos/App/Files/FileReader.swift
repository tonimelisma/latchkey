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

    /// Documents AppKit converts itself, each with its type named so the content is never sniffed
    /// as HTML (whose importer is WebKit and loads what the page links to).
    private static let documentTypes: [(UTType, NSAttributedString.DocumentType)] = {
        let named: [(UTType?, NSAttributedString.DocumentType)] = [
            (.rtfd, .rtfd), (.rtf, .rtf), (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
            (UTType("com.microsoft.word.doc"), .docFormat), (UTType("org.oasis-open.opendocument.text"), .openDocument),
        ]
        return named.compactMap { pair in pair.0.map { ($0, pair.1) } }
    }()

    private static func text(of url: URL, type: UTType) throws -> String? {
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { return nil }
            return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        if type.conforms(to: .webArchive) { return HTMLText.fromWebArchive(try contents(url)) }
        if type.conforms(to: .html) { return HTMLText.fromHTML(decode(try contents(url)) ?? "") }
        if let (_, documentType) = documentTypes.first(where: { type.conforms(to: $0.0) }) {
            return try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
                .string
        }
        let data = try contents(url)
        if data.prefix(8192).contains(0) {
            // UTF-16 text has zero bytes too; it starts with a byte order mark.
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                return String(data: data, encoding: .utf16)
            }
            return nil
        }
        return decode(data)
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
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

/// The readable text of a web page, without loading anything it links to (spec 003 research):
/// Foundation's XML parser in HTML-tidy mode builds the tree and is told never to load external
/// entities; it has no notion of images, style sheets, scripts, or frames, so it fetches nothing.
enum HTMLText {
    private static let skipped: Set<String> = [
        "head", "script", "style", "noscript", "template", "svg", "math", "object", "iframe", "frameset",
    ]
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol",
        "p", "pre", "section", "table", "tr", "ul",
    ]

    /// The HTML without its comments, in one pass: an opener with no end drops the rest
    /// (a regular expression took time with the square of a crafted message, security review
    /// 2026-10-30).
    static func withoutComments(_ html: String) -> String {
        var out = ""
        var rest = html[...]
        while let open = rest.range(of: "<!--") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    static func fromHTML(_ html: String) -> String {
        // Comments go first, Outlook's conditional ones (<!--[if mso]> … <![endif]-->) too: the
        // tidying parser can keep their markup as text (live check of a mail, 2026-10-30).
        let html = withoutComments(html)
        guard
            let doc = try? XMLDocument(
                xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        else { return stripped(html) }
        var out = ""
        walk(doc, into: &out, preformatted: false)
        return tidy(out)
    }

    /// A Safari web archive: a property list whose main resource holds the page's bytes. The
    /// archived subresources are never looked at.
    static func fromWebArchive(_ data: Data) -> String? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let main = plist["WebMainResource"] as? [String: Any],
            let body = main["WebResourceData"] as? Data
        else { return nil }
        var encoding = String.Encoding.utf8
        if let name = main["WebResourceTextEncodingName"] as? String {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                encoding = .init(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
        }
        guard let text = String(data: body, encoding: encoding) ?? String(data: body, encoding: .isoLatin1) else {
            return nil
        }
        let mime = (main["WebResourceMIMEType"] as? String ?? "text/html").lowercased()
        if mime.contains("html") { return fromHTML(text) }
        return mime.hasPrefix("text/") ? text : nil
    }

    private static func walk(_ node: XMLNode, into out: inout String, preformatted: Bool) {
        switch node.kind {
        case .text:
            let s = node.stringValue ?? ""
            if preformatted {
                out += s
            } else {
                let words = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !words.isEmpty else {
                    if !s.isEmpty, let last = out.last, !last.isWhitespace { out += " " }
                    return
                }
                if s.first?.isWhitespace == true, let last = out.last, !last.isWhitespace { out += " " }
                out += words
                if s.last?.isWhitespace == true { out += " " }
            }
        case .element:
            let name = node.name?.lowercased() ?? ""
            if skipped.contains(name) { return }
            let block = blocks.contains(name)
            if block { lineBreak(&out) }
            for child in node.children ?? [] { walk(child, into: &out, preformatted: preformatted || name == "pre") }
            if block { lineBreak(&out) }
            if name == "td" || name == "th" { out += "\t" }
        case .comment, .processingInstruction, .DTDKind, .entityDeclaration, .attribute, .namespace:
            return
        default:
            for child in node.children ?? [] { walk(child, into: &out, preformatted: preformatted) }
        }
    }

    private static func lineBreak(_ out: inout String) {
        while out.last == " " || out.last == "\t" { out.removeLast() }
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
    }

    /// Lines trimmed, at most one empty line in a row.
    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// When the page can't be parsed at all: the text between tags.
    private static func stripped(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return tidy(noTags.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
