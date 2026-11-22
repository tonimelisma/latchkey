import AppKit
import ApplicationServices
import Foundation

/// Codes a site texts to the Owner during Latchkey's own sign-in (spec 013 FR-1360 to FR-1363):
/// taken from Messages' database, filled by Latchkey, never shown to Claude, each text used once,
/// then deleted in Messages (at once while unlocked, else at the next unlock).
@MainActor
final class TextedCodes {
    static let shared = TextedCodes()

    /// A text received: its id, text, and when it arrived.
    struct Text: Sendable, Equatable {
        var id: String
        var text: String
        var date: Date
    }

    /// The texts not from the Owner that arrived since a moment, newest first; nil when Messages
    /// can't be read now. Tests give their own.
    typealias Recent = @Sendable (Date) -> [Text]?

    /// How long a site's request for a code is waited on, over one or more calls (FR-1361).
    var window: TimeInterval = 120

    /// Whether texts may be used: Messages isn't Off in Latchkey's settings. Set by the app; Off
    /// until then and in tests.
    var on: () -> Bool = { false }
    var recent: Recent = TextedCodes.fromMessages
    /// Emails from Apple Mail's index (FR-1364), read only when Claude has no email tool.
    var recentMail: Recent = { MailCodes.recent($0) }
    /// Starts Apple Mail hidden when it isn't running (FR-1365).
    var startMail: () async -> Void = { await MailCodes.start() }
    /// An email's text from Mail's scripting (FR-1365), for one whose body isn't downloaded yet.
    var mailContent: (MailCodes.Place) async -> String? = { try? await MailCodes.content($0) }
    /// How long one sign-in call waits for the text: within the relay's 60 s for a call, with
    /// time left for filling the code in.
    var perCall: Duration = .seconds(45)
    /// How long a call that hasn't been told about email waits for a text before asking Claude
    /// whether it can read the owner's email (FR-1364).
    var firstWait: Duration = .seconds(20)
    private var used: Set<String> = []
    /// The last code taken for each site, when, and whether it was tried again (FR-1361: a code a
    /// call took but couldn't finish with is tried once more by the next call; United, 2026-11-21).
    private var last: [String: (code: String, message: String, at: Date, again: Bool)] = [:]
    /// When each site first asked for a code, for the 2 minutes of FR-1361.
    private var requested: [String: Date] = [:]
    private let defaults: UserDefaults?
    static let pendingKey = "signInCodeTextsToDelete"

    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    /// The code in a code text: a run of 4 to 8 digits standing alone, next to a word like "code"
    /// or "OTP". A text without such a word is no code text, whatever numbers it holds (security
    /// review 2026-11-21: "meet at 1830" must never be filled in, nor deleted).
    nonisolated static func code(in text: String) -> String? {
        let ns = text as NSString
        // Not inside a word or a longer number; a code may run straight into the next sentence's
        // capital ("code.123456Please", IKEA's plain text, 2026-11-21), never into a small letter.
        guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\d{4,8}(?![\p{N}\p{Ll}])"#) else {
            return nil
        }
        let hits = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty else { return nil }
        let word =
            #"(?i)(code|otp|one[- ]time|passcode|pass code|verification|verify|security|2fa|pin|koodi|kod|código|codice|password|tunnus|vahvistus)"#
        for h in hits {
            let from = max(0, h.range.location - 40)
            let around = ns.substring(with: NSRange(location: from, length: min(ns.length - from, h.range.length + 80)))
            if around.range(of: word, options: .regularExpression) != nil { return ns.substring(with: h.range) }
        }
        return nil
    }

    /// When `site` first asked for a code: from the first sign-in call on it in the last 10
    /// minutes, since the code may be sent before Latchkey sees the code page (GitHub's "Send SMS"
    /// was pressed a call earlier and its text missed, 2026-11-21); noted now when it hadn't.
    func requested(_ site: String, now: Date = Date()) -> Date {
        if let at = requested[site], now.timeIntervalSince(at) < window { return at }
        let from = calls[site].flatMap { now.timeIntervalSince($0) < 600 ? $0 : nil } ?? now
        requested[site] = from
        return from
    }

    /// The first sign-in call on each site in the last 10 minutes.
    private var calls: [String: Date] = [:]
    /// When a button that sends a code was last pressed on each site.
    private var deliveredAt: [String: Date] = [:]

    func noteCall(_ site: String, now: Date = Date()) {
        if let at = calls[site], now.timeIntervalSince(at) < 600 { return }
        calls[site] = now
    }

    /// Whether a button that sends a code may be pressed: not within 90 s of the last, so each
    /// call doesn't send another text.
    func mayDeliver(_ site: String, now: Date = Date()) -> Bool {
        deliveredAt[site].map { now.timeIntervalSince($0) >= 90 } ?? true
    }

    func delivered(_ site: String, now: Date = Date()) { deliveredAt[site] = now }

    /// A code text (and with `mail`, a code email in Apple Mail) that arrived since `since` and
    /// wasn't used, waiting for one until `until`; the code and the text's id. Nil when none came,
    /// or neither texts nor (with `mail`) Mail can be used.
    func wait(
        since: Date, until: ContinuousClock.Instant, poll: Duration = .seconds(1), mail: Bool = false, site: String = ""
    ) async -> (code: String, message: String)? {
        let texts = on(), recent = recent, recentMail = recentMail
        guard texts || mail else { return nil }
        if mail { await startMail() }
        while true {
            // Messages and Mail date what arrives; a few seconds' slack for clocks and saving.
            let from = since.addingTimeInterval(-5)
            let found = await Task.detached { () -> [Text]? in
                let a = texts ? recent(from) : nil
                let b = mail ? recentMail(from) : nil
                return a == nil && b == nil ? nil : (a ?? []) + (b ?? [])
            }.value
            guard let texts = found else { return nil }
            for t in texts.sorted(by: { $0.date > $1.date }) where !used.contains(t.id) {
                // An email must name the site (security review 2026-11-21); a text may come from
                // anyone (Toni: "Any new code text").
                let place = MailCodes.Place(key: t.id)
                if place != nil, !MailCodes.names(site, in: t.text) { continue }
                var text = t.text
                // Mail lists a new email before it downloads its body (IKEA, 2026-11-21): the
                // body is asked of Mail's scripting, which downloads it, while the Mac is unlocked.
                if let place, Self.code(in: text) == nil, !isLocked(), let body = await mailContent(place) {
                    text += "\n" + body
                }
                if let code = Self.code(in: text) {
                    used.insert(t.id)
                    if !site.isEmpty { last[site] = (code, t.id, Date(), false) }
                    return (code, t.id)
                }
            }
            // No new one: the code an earlier call took for this site, once, while it is fresh.
            if !site.isEmpty, let l = last[site], !l.again, Date().timeIntervalSince(l.at) < 300 {
                last[site]?.again = true
                return (l.code, l.message)
            }
            guard ContinuousClock.now + poll < until else { return nil }
            try? await Task.sleep(for: poll)
        }
    }

    func forget(_ site: String) {
        requested[site] = nil
        calls[site] = nil
    }

    /// Whether a code step says the code went by text, not email ("sent to ******0790 via text").
    nonisolated static func saysText(_ page: String) -> Bool {
        let t = page.lowercased()
        let text = t.range(of: #"\b(via text|by text|text message|texted|sms)\b"#, options: .regularExpression) != nil
        return text && !t.contains("email") && !t.contains("e-mail")
    }

    /// The email in Apple Mail from the last 10 minutes holding exactly `code` (one Claude read with
    /// its own email tool), for archiving it (FR-1366); nil when Mail doesn't have it. Mail is
    /// only read here, never started.
    func mailHolding(_ code: String, site: String, now: Date = Date()) async -> String? {
        let recentMail = recentMail
        let from = now.addingTimeInterval(-600)
        let mails = await Task.detached { recentMail(from) }.value ?? []
        return mails.sorted { $0.date > $1.date }.first {
            Self.code(in: $0.text) == code && MailCodes.names(site, in: $0.text)
        }?.id
    }

    // MARK: deleting the text after use (FR-1362)

    /// The texts used and not yet deleted, kept across restarts.
    var pending: [String] {
        get { defaults?.stringArray(forKey: Self.pendingKey) ?? memoryPending }
        set {
            if let defaults { defaults.set(newValue, forKey: Self.pendingKey) } else { memoryPending = newValue }
        }
    }

    private var memoryPending: [String] = []
    /// Deletes a text in Messages' window, or marks an email read and archives it in Mail; throws
    /// why it couldn't. Tests give their own.
    var deleter: (String) async throws -> Void = { key in
        if let place = MailCodes.Place(key: key) {
            try await MailCodes.archive(place)
        } else {
            try await CodeTextWindow.delete(key)
        }
    }
    var isLocked: () -> Bool = { SystemScreen().isLocked() }
    /// Deleting is a change in Messages: only while Messages is Read & write in Latchkey's settings
    /// (security review 2026-11-21). Set by the app; true in tests.
    var mayDelete: () -> Bool = { true }
    private var deleting = false

    /// A code text was used: deleted now while unlocked, else at the next unlock.
    func used(_ message: String, site: String) async {
        let how = MailCodes.Place(key: message) == nil ? "texted" : "emailed (Apple Mail)"
        EventLog.shared.record(.app, "Sign-in on \(site): used a code \(how) to the owner")
        if !pending.contains(message) { pending.append(message) }
        await deletePending()
    }

    /// Deletes every text, and archives every email, waiting to be, while the Mac is unlocked.
    func deletePending() async {
        guard !deleting, !pending.isEmpty else { return }
        if !mayDelete(), pending.contains(where: { MailCodes.Place(key: $0) == nil }) {
            EventLog.shared.record(
                .app, "Used sign-in code texts stay in Messages: Messages isn't Read & write in Latchkey's settings")
            pending.removeAll { MailCodes.Place(key: $0) == nil }
        }
        guard !isLocked(), !pending.isEmpty else { return }
        deleting = true
        defer { deleting = false }
        for message in pending {
            let email = MailCodes.Place(key: message) != nil
            do {
                try await deleter(message)
                EventLog.shared.record(
                    .app,
                    email
                        ? "Marked a sign-in code email read and archived it in Mail after use"
                        : "Deleted a sign-in code text in Messages after use")
            } catch {
                let why =
                    (error as? CodeTextWindow.Problem)?.message
                    ?? (error as? ScriptError).map { e -> String in
                        guard email else { return MessagesCapability.explain(e) }
                        if case .notAllowed = e {
                            return
                                "Latchkey isn't allowed to control Mail. The Mac's owner can allow it in Latchkey's Settings → Permissions."
                        }
                        return MessagesCapability.explain(e).replacingOccurrences(of: "Messages", with: "Mail")
                    } ?? "\(error)"
                EventLog.shared.record(
                    .app, "A used sign-in code \(email ? "email stays in Mail" : "text stays in Messages"): \(why)",
                    error: true)
            }
            pending.removeAll { $0 == message }
        }
    }

    // MARK: Messages' database

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

    nonisolated static func fromMessages(_ since: Date) -> [Text]? {
        guard let store = store.get(),
            let found = try? store.search(text: nil, person: nil, since: since, until: nil, limit: 20)
        else { return nil }
        return found.filter { !$0.fromMe }.map { Text(id: $0.id, text: $0.text, date: $0.date) }
    }
}

/// Deleting one text in Messages' own window, in the background (spec 013 FR-1362; the way spec
/// 002's research found, 2026-11-05): show its conversation at the message without bringing
/// Messages forward, check the window shows that conversation, find the one message with its
/// text on the other side, Messages' own "Delete…", then the question's Delete. Done only once
/// Messages' database no longer lists it.
enum CodeTextWindow {
    struct Problem: Error, Equatable { var message: String }

    static let bundleID = "com.apple.MobileSMS"

    @MainActor
    static func delete(_ guid: String) async throws {
        guard AXIsProcessTrusted() else { throw Problem(message: "Latchkey isn't allowed to use Accessibility") }
        guard !SystemScreen().isLocked() else { throw Problem(message: "the Mac is locked") }
        guard let store = try? MessagesStore(url: Permissions.messagesDatabase, contacts: ContactBook()),
            let located = try store.locate(guid)
        else { return }  // gone already
        guard let identity = try store.identity(of: located.conversationID) else { return }
        try await show(guid, conversation: identity)
        let balloon = try await wait("the message") { () -> AXUIElement? in
            let hits = balloons().filter { !$0.fromMe && $0.text == located.text }
            return hits.count == 1 ? hits[0].element : nil
        }
        guard performNamed(balloon, "Delete…") else { throw Problem(message: "Messages doesn't offer deleting it") }
        try await confirmSheet()
        _ = try await wait("Messages to delete it", seconds: 10) { () -> Bool? in
            do { return try store.locate(guid) == nil ? true : nil } catch { return nil }
        }
    }

    // MARK: the window

    static func application() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        return ax
    }

    @MainActor
    static func show(_ guid: String, conversation: ConversationIdentity) async throws {
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "message-guid", value: guid)]
        guard let url = parts.url,
            let messages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { throw Problem(message: "Messages isn't on this Mac") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: messages, configuration: config)
        // Never act on whatever is shown: the window's title must name this conversation.
        do {
            _ = try await wait("the conversation") { () -> Bool? in
                guard let w = window(), let title = string(w, kAXTitleAttribute) else { return nil }
                return titleNames(title, conversation) ? true : nil
            }
        } catch {
            throw Problem(message: "Messages' window didn't show that conversation")
        }
        try? await Task.sleep(for: .milliseconds(400))  // the transcript scrolls to the message
    }

    static func window() -> AXUIElement? {
        guard let app = application() else { return nil }
        let windows = children(app, kAXWindowsAttribute)
        return windows.first { string($0, kAXIdentifierAttribute) == "SceneWindow" }
            ?? windows.first { string($0, kAXRoleAttribute) == "AXWindow" }
    }

    struct Balloon {
        var element: AXUIElement
        var text: String
        var fromMe: Bool
    }

    /// The messages shown in the conversation's transcript (never the replies view's): each an
    /// element with identifier "Sticker", its text its input label (macOS 27) or its text view's
    /// value; the Owner's on the right.
    static func balloons() -> [Balloon] {
        guard let w = window(),
            let t = first(
                in: w,
                {
                    string($0, kAXIdentifierAttribute) == "TranscriptCollectionView"
                        && string($0, kAXDescriptionAttribute) != "Reply transcript"
                })
        else { return [] }
        let middle = frame(t)?.midX ?? 0
        var list: [AXUIElement] = []
        all(in: t, { string($0, kAXIdentifierAttribute) == "Sticker" }, into: &list)
        return list.map { e in
            let text =
                inputLabel(e)
                ?? first(in: e, { string($0, kAXIdentifierAttribute) == "CKBalloonTextView" })
                .flatMap { string($0, kAXValueAttribute) } ?? ""
            return Balloon(element: e, text: text, fromMe: (frame(e)?.midX ?? 0) > middle)
        }
    }

    /// Presses the button of Messages' question ("Delete from all your devices?") that isn't Cancel.
    @MainActor
    static func confirmSheet() async throws {
        let sheet = try await wait("its question") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return children(w).first { string($0, kAXRoleAttribute) == "AXSheet" }
        }
        var cancel: AnyObject?
        AXUIElementCopyAttributeValue(sheet, kAXCancelButtonAttribute as CFString, &cancel)
        let buttons = children(sheet).filter { string($0, kAXRoleAttribute) == "AXButton" }
        guard
            let yes = buttons.last(where: { b in
                cancel.map { !CFEqual($0, b) } ?? (string(b, kAXTitleAttribute) != "Cancel")
            }), AXUIElementPerformAction(yes, kAXPressAction as CFString) == .success
        else { throw Problem(message: "Messages asked something Latchkey couldn't answer") }
    }

    /// Whether the window's title names this conversation: its own name, or each of its people
    /// (by name, number, or address) and no one else.
    static func titleNames(_ title: String, _ c: ConversationIdentity) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if let name = c.name, !name.isEmpty { return t == name }
        let parts = t.components(separatedBy: " & ").flatMap { $0.components(separatedBy: ", ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count == c.participants.count else { return false }
        var left = c.participants
        for part in parts {
            guard let i = left.firstIndex(where: { names(part, $0) }) else { return false }
            left.remove(at: i)
        }
        return left.isEmpty
    }

    static func names(_ part: String, _ p: MessagesStore.Participant) -> Bool {
        if let name = p.name, part == name { return true }
        if p.handle.contains("@") { return part.caseInsensitiveCompare(p.handle) == .orderedSame }
        let a = part.filter(\.isASCII).filter(\.isNumber)
        let b = p.handle.filter(\.isASCII).filter(\.isNumber)
        // Short codes (5 or 6 digits, as code texts come from) must match whole.
        if a.count < 7 || b.count < 7 { return !a.isEmpty && a == b }
        return a.hasSuffix(b) || b.hasSuffix(a)
    }

    // MARK: Accessibility helpers

    static func children(_ e: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func first(in e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(e) { return e }
        guard depth < 25 else { return nil }
        for c in children(e) {
            if let hit = first(in: c, depth: depth + 1, match) { return hit }
        }
        return nil
    }

    static func all(in e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool, into out: inout [AXUIElement]) {
        if match(e) {
            out.append(e)
            return
        }
        guard depth < 25 else { return }
        for c in children(e) { all(in: c, depth: depth + 1, match, into: &out) }
    }

    static func inputLabel(_ e: AXUIElement) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, "AXUserInputLabels" as CFString, &v) == .success,
            let labels = v as? [String], labels.count == 1, !labels[0].isEmpty
        else { return nil }
        return labels[0]
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        var p: AnyObject?
        var s: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
            AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success, let p, let s
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Performs a custom action ("Delete…") by its name.
    static func performNamed(_ e: AXUIElement, _ name: String) -> Bool {
        var v: CFArray?
        guard AXUIElementCopyActionNames(e, &v) == .success, let names = v as? [String] else { return false }
        guard let action = names.first(where: { $0 == name || $0.hasPrefix("Name:\(name)\n") }) else { return false }
        return AXUIElementPerformAction(e, action as CFString) == .success
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    @MainActor
    static func wait<T>(_ what: String, seconds: Double = 5, _ look: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let found = look() { return found }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw Problem(message: "Messages' window didn't show \(what)")
    }
}
