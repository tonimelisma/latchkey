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

    func tokens(_ field: RecipientField) -> [String] {
        switch field {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }
}

enum RecipientField: String, Sendable, CaseIterable { case to, cc, bcc }

/// One compose window. Every call may fail with `ComposeFailure`.
protocol ComposeWindow: Sendable {
    func fields() async throws -> ComposeFields
    /// Chooses the From pop-up item for this address; false when Mail offers none.
    func chooseSender(_ address: String) async throws -> Bool
    /// Adds recipients to a field (replies and forwards).
    func addRecipients(_ addresses: [String], to field: RecipientField) async throws
    /// Puts the text where Mail put the cursor (the top of the body).
    func insertText(_ text: String) async throws
    /// Gives Mail the files to attach.
    func attachFiles(_ files: [URL]) async throws
    func send() async throws
    func saveDraft() async throws
    /// Closes the window without saving or sending; false when it is still open after.
    func discard() async -> Bool
}

/// Mail's windows, through Accessibility. A protocol so tests never touch Mail or the screen.
protocol ComposeWindows: Sendable {
    /// Why the window can't be used now (screen off or locked, no Accessibility); nil when it can.
    func unavailable() async -> String?
    func open(_ how: ComposeOpening) async throws -> any ComposeWindow
    /// Puts the Owner's front app back once the window work is done.
    func finish() async
}

struct ComposeFailure: Error, Equatable {
    var message: String
    /// Failed after Send was pressed, so Mail may have sent it: never "Nothing was sent", and
    /// never tried again by the queue (spec 008 FR-838, security review 2026-11-02).
    var afterSend = false
}

/// An address the window may show, and the names Mail may show for it instead (the name in
/// the original's header, or the contact's name in Contacts).
struct KnownAddress: Sendable, Equatable {
    var address: String
    var names: [String] = []

    /// Whether a token in Mail's window stands for this address. A token is the address itself,
    /// "Name <address>", or one of the address's names.
    func matches(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if MailWrite.bare(t).caseInsensitiveCompare(address) == .orderedSame { return true }
        guard !t.contains("@") else { return false }
        return names.contains { !$0.isEmpty && $0.caseInsensitiveCompare(t) == .orderedSame }
    }
}

/// What Mail's own Reply, Reply All, or Forward must have put in the window for the original
/// the store names (security review 2026-10-30: `message://` opens by Message-ID, which anyone
/// can copy, so the window is compared with the message Claude chose).
struct ResponsePrefill: Sendable, Equatable {
    /// The original's subject.
    var subject: String
    /// Recipients Mail may fill in for this response (To and Cc).
    var allowed: [KnownAddress] = []
    /// At least one of these must be filled in (the one replied to); empty for a forward.
    var required: [KnownAddress] = []
    /// The Owner's own addresses: Mail may add them anywhere ("Automatically Cc/Bcc myself").
    var own: [KnownAddress] = []
    /// A forward: the original's attachment names (the window may show no others).
    var attachments: [String]?
}

/// The steps of writing one message in the window, with every field checked before it goes
/// (plan D6). On any failure the window is closed without sending or saving.
enum MailCompose {
    struct Request: Sendable {
        var opening: ComposeOpening
        var to: [KnownAddress] = []
        var cc: [KnownAddress] = []
        var bcc: [KnownAddress] = []
        /// For a new message: the subject the window must show.
        var subject: String?
        /// For a response: what Mail must have filled in.
        var prefill: ResponsePrefill?
        /// The Owner's own addresses (Mail's "Automatically Cc/Bcc myself" may add one).
        var own: [KnownAddress] = []
        /// The address to send from; nil leaves Mail's choice (its default, or for a response
        /// the account the original came to).
        var sender: String?
        var text: String
        var files: [URL]
        var draft: Bool

        func requested(_ field: RecipientField) -> [KnownAddress] {
            switch field {
            case .to: to
            case .cc: cc
            case .bcc: bcc
            }
        }
    }

    /// How long Mail gets to attach files.
    static let attachWait: Duration = .seconds(15)

    /// Returns the subject the window showed (Mail's "Re:"/"Fwd:" for a response).
    static func run(
        _ r: Request, _ windows: any ComposeWindows, attachWait: Duration = attachWait,
        poll: Duration = .milliseconds(100)
    ) async throws -> String {
        if let why = await windows.unavailable() { throw ComposeFailure(message: why) }
        let window: any ComposeWindow
        do { window = try await windows.open(r.opening) } catch {
            await uncancelled { await windows.finish() }
            throw error
        }
        do {
            // What Mail filled in before Latchkey touched the window.
            let prefilled = try await window.fields()
            if let p = r.prefill { try checkPrefill(p, prefilled) }
            if let sender = r.sender, !prefilled.from.lowercased().contains(sender.lowercased()) {
                guard try await window.chooseSender(sender) else {
                    throw ComposeFailure(message: "Mail offers no From address \(sender).")
                }
            }
            if case .respond = r.opening {
                for field in RecipientField.allCases where !r.requested(field).isEmpty {
                    try await window.addRecipients(r.requested(field).map(\.address), to: field)
                }
            }
            if !r.text.isEmpty { try await window.insertText(r.text) }
            if !r.files.isEmpty { try await window.attachFiles(r.files) }
            // Mail attaches files a moment later; look again until they are all there.
            var f = try await window.fields()
            let deadline = ContinuousClock.now + attachWait
            while missingFiles(r.files, f) > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: poll)
                f = try await window.fields()
            }
            try check(r, prefilled: prefilled, f)
            // Nothing may change between the check and Send (someone typing meanwhile).
            guard try await window.fields() == f else {
                throw ComposeFailure(message: "Mail's window changed while Latchkey was checking it")
            }
            // A call given up meanwhile (Claude stopped, the connection ended) sends nothing.
            try Task.checkCancellation()
            if r.draft { try await window.saveDraft() } else { try await window.send() }
            await uncancelled { await windows.finish() }
            return f.subject
        } catch {
            let closed = await uncancelled { await window.discard() }
            await uncancelled { await windows.finish() }
            guard closed else {
                let why = (error as? ComposeFailure)?.message ?? "\(error)"
                throw ComposeFailure(
                    message: "\(why). Mail's window couldn't be closed: it is still open on the screen, unsent.")
            }
            throw error
        }
    }

    /// Runs cleanup to its end even when the tool call was cancelled (its waits would return at once).
    static func uncancelled<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task { await work() }.value
    }

    static func missingFiles(_ files: [URL], _ f: ComposeFields) -> Int {
        files.filter { url in !f.attachments.contains { attachmentName($0) == url.lastPathComponent } }.count
    }

    /// The file name in Mail's attachment token ("lease.pdf, 2 KB"): compared whole, never by its
    /// start, so "lease.pdf.exe" isn't taken for "lease.pdf" (security review, 2026-10-30).
    static func attachmentName(_ token: String) -> String {
        guard let m = token.firstMatch(of: /^(.*), [0-9][0-9.,]* ?(bytes|byte|KB|kB|MB|GB|TB)$/) else { return token }
        return String(m.output.1)
    }

    /// Mail's Reply, Reply All, or Forward opened the message Claude chose: its subject, and
    /// recipients only the original's (plan D6, security review 2026-10-30).
    static func checkPrefill(_ p: ResponsePrefill, _ f: ComposeFields) throws {
        func fail(_ why: String) throws -> Never {
            throw ComposeFailure(message: "the window Mail opened isn't a response to that message (\(why))")
        }
        if f.subject.isEmpty || MailStore.bareSubject(f.subject) != MailStore.bareSubject(p.subject) {
            try fail("its subject is «\(f.subject)»")
        }
        for token in f.to + f.cc where !(p.allowed + p.own).contains(where: { $0.matches(token) }) {
            try fail("it is addressed to \(token)")
        }
        for token in f.bcc where !p.own.contains(where: { $0.matches(token) }) {
            try fail("its Bcc has \(token)")
        }
        if !p.required.isEmpty, !(f.to + f.cc).contains(where: { t in p.required.contains { $0.matches(t) } }) {
            try fail("it isn't addressed to \(p.required.map(\.address).joined(separator: " or "))")
        }
        if let names = p.attachments {
            for a in f.attachments where !names.contains(where: { !$0.isEmpty && attachmentName(a) == $0 }) {
                try fail("it carries an attachment the message doesn't have, \(a)")
            }
        }
    }

    /// Pairs each token with a requested address, one to one: the tokens and addresses left over.
    static func pair(_ tokens: [String], _ wanted: [KnownAddress]) -> (extra: [String], missing: [KnownAddress]) {
        var left = wanted
        var extra: [String] = []
        // Exact addresses first, so a name shared by two contacts can't take another's place.
        var rest: [String] = []
        for t in tokens {
            if let i = left.firstIndex(where: { MailWrite.bare(t).caseInsensitiveCompare($0.address) == .orderedSame })
            {
                left.remove(at: i)
            } else {
                rest.append(t)
            }
        }
        for t in rest {
            if let i = left.firstIndex(where: { $0.matches(t) }) { left.remove(at: i) } else { extra.append(t) }
        }
        return (extra, left)
    }

    /// Every field as asked, before anything is sent (plan D6).
    static func check(_ r: Request, prefilled: ComposeFields, _ f: ComposeFields) throws {
        func fail(_ why: String) throws -> Never { throw ComposeFailure(message: why) }
        if let subject = r.subject, f.subject != subject {
            try fail("the subject in Mail's window is «\(f.subject)», not «\(subject)»")
        }
        if case .respond = r.opening, f.subject.isEmpty { try fail("Mail's window has no subject") }
        let isNew = if case .new = r.opening { true } else { false }
        // Recipients (security review 2026-10-30): exactly the ones asked for, plus, for a
        // response, what Mail itself filled in (checked against the original above); the Owner's
        // own address only where Mail put it at the start.
        for field in RecipientField.allCases {
            let name = field.rawValue.capitalized
            let wanted = r.requested(field)
            var shown = f.tokens(field)
            var fromMail = prefilled.tokens(field)
            if !isNew {
                // Mail's own recipients stay as they were; what was added is exactly the request
                // (an address Mail already had may not be shown twice).
                for t in fromMail {
                    guard let i = shown.firstIndex(of: t) else { try fail("Mail's \(name) field no longer has \(t)") }
                    shown.remove(at: i)
                }
                let (extra, missing) = pair(shown, wanted)
                if let e = extra.first { try fail("Mail's \(name) field has \(e), which wasn't asked for") }
                for m in missing where !fromMail.contains(where: { m.matches($0) }) {
                    try fail("Mail's \(name) field is missing \(m.address)")
                }
            } else {
                // A new message: the request, and beyond it only the Owner's own address where
                // Mail put it when the window opened.
                let (extra, missing) = pair(shown, wanted)
                for e in extra {
                    guard let i = fromMail.firstIndex(of: e), r.own.contains(where: { $0.matches(e) }) else {
                        try fail("Mail's \(name) field has \(e), which wasn't asked for")
                    }
                    fromMail.remove(at: i)
                }
                if let m = missing.first { try fail("Mail's \(name) field is missing \(m.address)") }
            }
        }
        if case .respond(_, let kind) = r.opening, kind == .forward, f.to.isEmpty {
            try fail("the forward has no recipient")
        }
        if f.to.isEmpty && f.cc.isEmpty && f.bcc.isEmpty, !r.draft { try fail("Mail's window has no recipient") }
        if let sender = r.sender, !f.from.lowercased().contains(sender.lowercased()) {
            try fail("Mail's From is «\(f.from)», not \(sender)")
        }
        let wanted = collapse(r.text)
        if !wanted.isEmpty {
            let unquoted = collapse(f.body.filter { $0.quoteLevel == 0 }.map(\.text).joined(separator: "\n"))
            guard unquoted.hasPrefix(wanted) else {
                try fail("the text in Mail's window isn't the text given (or Mail marked it as quoted)")
            }
        }
        if missingFiles(r.files, f) > 0 {
            try fail("Mail attached \(r.files.count - missingFiles(r.files, f)) of \(r.files.count) files")
        }
        if let names = r.prefill?.attachments {
            let ours = r.files.map(\.lastPathComponent)
            for a in f.attachments where !(names + ours).contains(where: { !$0.isEmpty && attachmentName(a) == $0 }) {
                try fail("Mail's window has an attachment that wasn't asked for, \(a)")
            }
        } else if case .new = r.opening, f.attachments.count != r.files.count {
            try fail("Mail's window has \(f.attachments.count) attachments, not \(r.files.count)")
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).joined(separator: " ")
    }

    /// `mailto:` with recipients and subject only; the text is put in the window, never the link.
    static func mailto(to: [String], cc: [String], bcc: [String], subject: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@,")
        var c = URLComponents()
        c.scheme = "mailto"
        c.percentEncodedPath = to.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var items: [URLQueryItem] = []
        if !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if !bcc.isEmpty { items.append(URLQueryItem(name: "bcc", value: bcc.joined(separator: ","))) }
        items.append(URLQueryItem(name: "subject", value: subject))
        // URLComponents leaves "&", "=", "+" and "?" alone in values; a subject must not end the
        // field or start another.
        c.percentEncodedQuery = items.map { item in
            "\(item.name)=\(item.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
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
