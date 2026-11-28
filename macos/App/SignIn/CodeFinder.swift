import Foundation

/// Finding a site's sign-in code in the Owner's texts and email, for the two ways of the codes
/// experiment where Latchkey takes part (decided 2026-11-22: "test all approaches for robustness on
/// a wide variety of web sites"; spec 013 FR-1376): Latchkey fetches the code itself, or checks
/// that a code Claude passes really came from that site. Read from Messages' database and Apple
/// Mail's files, never a window.
@MainActor
final class CodeFinder {
    static let shared = CodeFinder()

    /// A text or an email: its id (Messages' id, or a `MailCodes.Place` key), its text, and when
    /// it arrived.
    struct Message: Sendable, Equatable {
        var id: String
        var text: String
        var date: Date
    }

    /// The messages that arrived since a moment, newest first; nil when they can't be read now.
    typealias Recent = @Sendable (Date) -> [Message]?

    /// Whether texts may be read (Messages isn't Off in Latchkey's settings), and email (Mail isn't
    /// Off). Set by the app; Off until then and in tests.
    var textsOn: () -> Bool = { false }
    var mailOn: () -> Bool = { false }
    var texts: Recent = CodeFinder.fromMessages
    var mail: Recent = { since in CodeFinder.fromMail(since) }
    var startMail: () async -> Void = { await MailCodes.start() }
    /// How long a read of Messages' database or Mail's files may take, its wait for a thread
    /// included (Constitution II). On a busy runner a read waited 21 to 31 s for a thread (mac
    /// build, 2026-11-24), so tests never measure it in real time.
    var readLimit: Duration = .seconds(10)
    /// The clock `readLimit` is measured on; tests move one by hand (spec 016 FR-1602).
    var clock: any Clock<Duration> = ContinuousClock()
    private var used: Set<String> = []
    /// When Latchkey last typed a password on each site: codes are looked for since then.
    private var passwords: [String: Date] = [:]

    init() {}

    /// The code in a code text: a run of 4 to 8 digits standing alone, next to a word like "code"
    /// or "OTP". A text without such a word is no code text, whatever numbers it holds (security
    /// review 2026-11-21: "meet at 1830" is never a code).
    nonisolated static func code(in text: String) -> String? {
        if let bound = bound(text) { return bound.code }
        let ns = text as NSString
        // Not inside a word or a longer number; a code may run straight into the next sentence's
        // capital ("code.123456Please", IKEA's plain text, 2026-11-21), never into a small letter.
        guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\d{4,8}(?![\p{N}\p{Ll}])"#) else {
            return nil
        }
        let hits = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let word =
            #"(?i)(code|otp|one[- ]time|passcode|pass code|verification|verify|security|2fa|pin|koodi|kod|código|codice|password|tunnus|vahvistus)"#
        for h in hits {
            let from = max(0, h.range.location - 40)
            let around = ns.substring(with: NSRange(location: from, length: min(ns.length - from, h.range.length + 80)))
            if around.range(of: word, options: .regularExpression) != nil { return ns.substring(with: h.range) }
        }
        return nil
    }

    /// The site-bound line Apple and Google defined for code texts (WICG "Origin-bound one-time
    /// codes delivered via SMS"): the text's last line is `@<domain> #<code>`, optionally followed
    /// by ` @<embedded domain>`. The domain and the code, when the text has one.
    nonisolated static func bound(_ text: String) -> (domain: String, code: String)? {
        guard let last = text.split(whereSeparator: \.isNewline).last.map(String.init) else { return nil }
        guard
            let m = last.range(
                of: #"^@([A-Za-z0-9.-]+) #([A-Za-z0-9]{4,10})(?: @[A-Za-z0-9.-]+)?\s*$"#, options: .regularExpression)
        else { return nil }
        let parts = last[m].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0].dropFirst()).lowercased(), String(parts[1].dropFirst()))
    }

    /// Whether a message may hold `site`'s code: a site-bound line must name the site; without one,
    /// an email must name the site (its sender or text; security review 2026-11-21), and a text may
    /// come from anyone (decided 2026-11-21: "Any new code text").
    nonisolated static func mayBe(_ m: Message, for site: String) -> Bool {
        if let b = bound(m.text) { return SiteMatch.fills(site: site, on: "https://\(b.domain)/") }
        if MailCodes.Place(key: m.id) != nil { return MailCodes.names(site, in: m.text) }
        return true
    }

    /// Notes that Latchkey typed `site`'s password now.
    func passwordTyped(_ site: String, at: Date = Date()) { passwords[site] = at }

    /// Since when a code for `site` counts: the last password Latchkey typed there in the last 10
    /// minutes, else only the last 3 minutes (security review 2026-11-22).
    func since(_ site: String, now: Date = Date()) -> Date {
        guard let at = passwords[site], at > now.addingTimeInterval(-600) else { return now.addingTimeInterval(-180) }
        return at
    }

    /// Whether texts (or email) may be read now.
    func readable(email: Bool) -> Bool { email ? mailOn() : textsOn() }

    /// Notes that the code of message `id` was typed: it is never taken again.
    func markUsed(_ id: String) { used.insert(id) }

    private func messages(since: Date, email: Bool) async -> [Message]? {
        let on = email ? mailOn() : textsOn()
        guard on else { return nil }
        if email { await startMail() }
        let source = email ? mail : texts
        let from = since.addingTimeInterval(-5)  // clocks and saving
        // Database and file reads block: on a GCD queue, never Swift's shared pool
        // (.claude/rules/macos.md), within the read limit (Constitution II).
        return await Deadline.first(within: readLimit, clock: clock) {
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: source(from)) }
            }
        }
    }

    /// Newest first, a message that names the site before one that doesn't: of two codes that
    /// came together, the one about this site (security review 2026-11-22).
    private nonisolated static func ordered(_ found: [Message], for site: String) -> [Message] {
        found.sorted { a, b in
            let na = MailCodes.names(site, in: a.text), nb = MailCodes.names(site, in: b.text)
            return na != nb ? na : a.date > b.date
        }
    }

    /// Way 2: the newest unused code for `site` in a text (or an email) since `since`; nil when none
    /// has come, or texts (email) can't be read.
    func find(site: String, email: Bool, since: Date) async -> (code: String, id: String)? {
        guard let found = await messages(since: since, email: email) else { return nil }
        for m in Self.ordered(found, for: site) where !used.contains(m.id) && Self.mayBe(m, for: site) {
            if let code = Self.code(in: m.text) { return (code, m.id) }
        }
        return nil
    }

    /// Way 3: the message holding exactly `code` for `site` since `since`, in texts or email; nil
    /// when none does.
    func holding(_ code: String, site: String, since: Date) async -> String? {
        for email in [false, true] {
            guard let found = await messages(since: since, email: email) else { continue }
            // A message whose code was typed once is never taken again (security review 2026-11-22).
            if let m = Self.ordered(found, for: site).first(where: {
                !used.contains($0.id) && Self.mayBe($0, for: site) && Self.code(in: $0.text) == code
            }) {
                return m.id
            }
        }
        return nil
    }

    // MARK: reading

    private nonisolated static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: MessagesStore?
        func get() -> MessagesStore? {
            lock.withLock {
                if let opened { return opened }
                opened = try? MessagesStore(url: Permissions.messagesDatabase, contacts: ContactBook())
                return opened
            }
        }
    }

    nonisolated static func fromMessages(_ since: Date) -> [Message]? {
        guard let store = store.get(),
            let found = try? store.search(text: nil, person: nil, since: since, until: nil, limit: 100)
        else { return nil }
        return found.filter { !$0.fromMe }.map { Message(id: $0.id, text: $0.text, date: $0.date) }
    }

    nonisolated static func fromMail(_ since: Date) -> [Message]? {
        guard let emails = MailCodes.find(since: since, limit: 20) else { return nil }
        return emails.map { e in
            Message(
                id: e.place.key,
                text: ["From: " + e.sender, e.subject, MailCodes.text(of: e) ?? ""].joined(separator: "\n"),
                date: e.date)
        }
    }
}
