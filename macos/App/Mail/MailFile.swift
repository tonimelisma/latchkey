import Foundation
import MimeFoundation

/// One message file of Mail's (`.emlx`): a byte count, the RFC 822 message, Apple's property
/// list (plan D2). The message is parsed with MimeFoundation.
struct MailFile: Sendable {
    struct Attachment: Sendable, Equatable {
        var number: Int
        var name: String
        var mimeType: String
        var size: Int
        /// The decoded bytes; nil when the part isn't in the file (a partial message).
        var data: Data?
    }

    /// The text, plain if the message has it, otherwise its HTML as text; nil when there is none.
    var text: String?
    var attachments: [Attachment]
    var partial: Bool
    var date: Date?
    var from: String
    var messageID: String?
    /// The Reply-To header's addresses (where Mail's Reply sends), with their names.
    var replyTo: [(address: String, name: String)] = []

    struct Unreadable: Error {}

    static let maxBytes = 60_000_000

    static func read(_ url: URL) throws -> MailFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        return try parse(data, partial: url.lastPathComponent.hasSuffix(".partial.emlx"))
    }

    /// The RFC 822 part of an `.emlx`'s bytes.
    static func message(in data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A),
            let count = Int(
                String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces))
        else { return data }
        let start = data.index(after: newline)
        let end = min(data.endIndex, start + max(count, 0))
        return data[start..<end]
    }

    /// The message's text: its plain part, or its HTML as text when it has no plain part or the
    /// plain part is itself HTML (many senders put the HTML there too; live check 2026-10-30).
    static func readableText(plain: String?, html: String?) -> String? {
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return looksLikeHTML(plain) ? HTMLText.fromHTML(plain) : plain
        }
        return html.map(HTMLText.fromHTML)
    }

    /// True when text is mostly markup: an html or body tag, or several table, paragraph, or
    /// break tags. A stray "<" in ordinary text is not.
    static func looksLikeHTML(_ s: String) -> Bool {
        if s.range(of: #"<\s*(html|body)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let tags = s.matches(of: /(?i)<\/?\s*(table|tr|td|div|p|br|span|font)\b[^>]*>/).count
        return tags >= 3
    }

    static func parse(_ emlx: Data, partial: Bool) throws -> MailFile {
        let raw = message(in: emlx)
        let msg: MimeMessage
        do { msg = try MimeMessage.load(MemoryStream([UInt8](raw), writable: false)) } catch { throw Unreadable() }
        let text = readableText(plain: msg.textBody, html: msg.htmlBody)
        var attachments: [Attachment] = []
        for part in msg.bodyParts {
            guard let p = part as? MimePart else { continue }
            // The message's own text parts aren't attachments; a text file attached is.
            if p is TextPart && p.fileName == nil && p.contentDisposition?.isAttachment != true { continue }
            let bytes = decoded(p)
            let declared = p.headers["X-Apple-Content-Length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let present = bytes.map { !$0.isEmpty } ?? false
            attachments.append(
                Attachment(
                    number: attachments.count + 1,
                    name: p.fileName ?? "attachment \(attachments.count + 1)",
                    mimeType: p.contentType.mimeType.lowercased(),
                    size: present ? bytes!.count : declared ?? bytes?.count ?? 0,
                    data: present ? bytes : nil))
        }
        let from = msg.from.mailboxes.first.map { m in
            m.name.map { "\($0) <\(m.address)>" } ?? m.address
        }
        return MailFile(
            text: text, attachments: attachments, partial: partial, date: msg.date?.date, from: from ?? "",
            messageID: msg.messageId,
            replyTo: msg.replyTo.mailboxes.map { (address: $0.address, name: $0.name ?? "") })
    }

    private static func decoded(_ p: MimePart) -> Data? {
        guard let content = p.content else { return nil }
        let out = MemoryBlockStream()
        do {
            try content.decodeTo(out)
            return Data(try out.toArray())
        } catch { return nil }
    }
}
