import Foundation

/// Writing email through Mail's own compose window, driven through Accessibility, so what is
/// sent is ordinary mail (Toni, 2026-10-30; spec 008 plan D6). Text set through Mail's scripting
/// arrives marked as quoted (research "Live check"); scripting is never used to compose.

/// How a compose window is opened.
enum ComposeOpening: Sendable, Equatable {
    /// A new message from a `mailto:` link (recipients and subject only).
    case new(mailto: URL)
    /// Mail's Reply, Reply All, or Forward on the original, opened by its Message-ID.
    case respond(messageID: String, kind: ResponseKind)
}

enum ResponseKind: String, Sendable, Equatable {
    case reply, replyAll, forward
}

/// What the compose window shows, read back through Accessibility before sending.
struct ComposeFields: Sendable, Equatable {
    /// The recipients' tokens as Mail shows them: an address, or a contact's name.
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    /// The From pop-up's value ("Name – address").
    var from = ""
    /// Text runs of the body with how deep in a quote each is (0: not quoted).
    var body: [(text: String, quoteLevel: Int)] = []
    /// Attachments' descriptions ("note.txt, 21 bytes").
    var attachments: [String] = []

    static func == (a: ComposeFields, b: ComposeFields) -> Bool {
        a.to == b.to && a.cc == b.cc && a.bcc == b.bcc && a.subject == b.subject && a.from == b.from
            && a.attachments == b.attachments && a.body.map(\.text) == b.body.map(\.text)
            && a.body.map(\.quoteLevel) == b.body.map(\.quoteLevel)
    }
}

enum RecipientField: String, Sendable { case to, cc, bcc }

/// One compose window. Every call may fail with `ComposeFailure`.
protocol ComposeWindow: Sendable {
    func fields() async throws -> ComposeFields
    /// Chooses the From pop-up item for this address; false when Mail offers none.
    func chooseSender(_ address: String) async throws -> Bool
    /// Adds recipients to a field by pasting them into it (replies and forwards).
    func addRecipients(_ addresses: [String], to field: RecipientField) async throws
    /// Pastes the text where Mail put the cursor (the top of the body).
    func pasteText(_ text: String) async throws
    /// Pastes the files, which Mail attaches.
    func pasteFiles(_ files: [URL]) async throws
    func send() async throws
    func saveDraft() async throws
    /// Closes the window without saving or sending.
    func discard() async
}

/// Mail's windows, through Accessibility. A protocol so tests never touch Mail or the screen.
protocol ComposeWindows: Sendable {
    /// Why the window can't be used now (screen off or locked, no Accessibility); nil when it can.
    func unavailable() async -> String?
    func open(_ how: ComposeOpening) async throws -> any ComposeWindow
    /// Puts the Owner's front app and clipboard back once the window work is done.
    func finish() async
}

struct ComposeFailure: Error, Equatable {
    var message: String
}

/// The steps of writing one message in the window, with every field checked before it goes
/// (plan D6). On any failure the window is closed without sending or saving.
enum MailCompose {
    struct Request: Sendable {
        var opening: ComposeOpening
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        /// For a new message: the subject the window must show.
        var subject: String?
        /// The address to send from; nil leaves Mail's choice (its default, or for a response
        /// the account the original came to).
        var sender: String?
        var text: String
        var files: [URL]
        var draft: Bool
    }

    /// How long Mail gets to attach pasted files.
    static let attachWait: Duration = .seconds(15)

    /// Returns the subject the window showed (Mail's "Re:"/"Fwd:" for a response).
    static func run(
        _ r: Request, _ windows: any ComposeWindows, attachWait: Duration = attachWait,
        poll: Duration = .milliseconds(100)
    ) async throws -> String {
        if let why = await windows.unavailable() { throw ComposeFailure(message: why) }
        let window: any ComposeWindow
        do { window = try await windows.open(r.opening) } catch {
            await windows.finish()
            throw error
        }
        do {
            if let sender = r.sender {
                let now = try await window.fields().from
                if !now.lowercased().contains(sender.lowercased()) {
                    guard try await window.chooseSender(sender) else {
                        throw ComposeFailure(message: "Mail offers no From address \(sender).")
                    }
                }
            }
            if case .respond = r.opening {
                if !r.to.isEmpty { try await window.addRecipients(r.to, to: .to) }
                if !r.cc.isEmpty { try await window.addRecipients(r.cc, to: .cc) }
                if !r.bcc.isEmpty { try await window.addRecipients(r.bcc, to: .bcc) }
            }
            if !r.text.isEmpty { try await window.pasteText(r.text) }
            if !r.files.isEmpty { try await window.pasteFiles(r.files) }
            // Mail attaches pasted files a moment later; look again until they are all there.
            var f = try await window.fields()
            let deadline = ContinuousClock.now + attachWait
            while missingFiles(r.files, f) > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: poll)
                f = try await window.fields()
            }
            try check(r, f)
            if r.draft { try await window.saveDraft() } else { try await window.send() }
            await windows.finish()
            return f.subject
        } catch {
            await window.discard()
            await windows.finish()
            throw error
        }
    }

    static func missingFiles(_ files: [URL], _ f: ComposeFields) -> Int {
        files.filter { url in !f.attachments.contains { $0.hasPrefix(url.lastPathComponent) } }.count
    }

    /// Every field as asked, before anything is sent (plan D6).
    static func check(_ r: Request, _ f: ComposeFields) throws {
        func fail(_ why: String) throws -> Never { throw ComposeFailure(message: why) }
        if let subject = r.subject, f.subject != subject {
            try fail("the subject in Mail's window is «\(f.subject)», not «\(subject)»")
        }
        if case .respond = r.opening, f.subject.isEmpty { try fail("Mail's window has no subject") }
        let isNew = if case .new = r.opening { true } else { false }
        for (field, wanted, shown) in [("To", r.to, f.to), ("Cc", r.cc, f.cc), ("Bcc", r.bcc, f.bcc)] {
            if isNew {
                if shown.count != wanted.count {
                    try fail("Mail's \(field) field shows \(shown.count) recipients, not \(wanted.count)")
                }
                // A token shows the address, or the contact's name for an address in Contacts.
                let asked = Set(wanted.map { $0.lowercased() })
                for token in shown where token.contains("@") && !asked.contains(token.lowercased()) {
                    try fail("Mail's \(field) field has \(token), which wasn't asked for")
                }
            } else if shown.count < wanted.count {
                try fail("Mail's \(field) field is missing recipients")
            }
        }
        if case .respond(_, let kind) = r.opening, kind == .forward, f.to.isEmpty {
            try fail("the forward has no recipient")
        }
        if case .new = r.opening, f.to.isEmpty && f.cc.isEmpty && f.bcc.isEmpty, !r.draft {
            try fail("Mail's window has no recipient")
        }
        if let sender = r.sender, !f.from.lowercased().contains(sender.lowercased()) {
            try fail("Mail's From is «\(f.from)», not \(sender)")
        }
        let wanted = collapse(r.text)
        if !wanted.isEmpty {
            let unquoted = collapse(f.body.filter { $0.quoteLevel == 0 }.map(\.text).joined(separator: "\n"))
            guard unquoted.hasPrefix(wanted) || unquoted == wanted else {
                try fail("the text in Mail's window isn't the text given (or Mail marked it as quoted)")
            }
        }
        if missingFiles(r.files, f) > 0 {
            try fail("Mail attached \(r.files.count - missingFiles(r.files, f)) of \(r.files.count) files")
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).joined(separator: " ")
    }

    /// `mailto:` with recipients and subject only; the text is pasted, never put in the link.
    static func mailto(to: [String], cc: [String], bcc: [String], subject: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@,")
        var c = URLComponents()
        c.scheme = "mailto"
        c.percentEncodedPath = to.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var items: [URLQueryItem] = []
        if !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if !bcc.isEmpty { items.append(URLQueryItem(name: "bcc", value: bcc.joined(separator: ","))) }
        items.append(URLQueryItem(name: "subject", value: subject))
        c.queryItems = items
        // URLComponents leaves "&", "=", "+" and "?" alone in values; a subject must not end the
        // field or start another.
        c.percentEncodedQuery = c.queryItems?.map { item in
            return "\(item.name)=\(item.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return c.url
    }
}

/// One email written at a time: two at once would paste into each other's windows.
actor ComposeQueue {
    private var busy = false

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        guard !busy else {
            throw ComposeFailure(message: "Mail is busy writing another email for Claude; try again in a moment.")
        }
        busy = true
        defer { busy = false }
        return try await work()
    }
}
