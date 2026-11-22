import AppKit
import ApplicationServices
import Foundation

/// What Claude asked to clean up after reading a sign-in code itself (Toni, 2026-11-22: "The
/// agent reads the messages, archives them etc"): a message in Messages deleted (spec 002
/// FR-180), an email in Apple Mail marked read and archived (spec 008 FR-852). Done at once while
/// the Mac is unlocked; while it is locked (Messages' window and Mail's scripting freeze behind
/// the lock, 2026-11-02), at the next unlock, also after a restart in between.
@MainActor
final class PendingCleanup {
    static let shared = PendingCleanup()

    private let defaults: UserDefaults?
    /// The list kept across restarts (the name it had when it held only code texts).
    static let pendingKey = "signInCodeTextsToDelete"

    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    /// What is waiting for the unlock: Messages' ids, and emails' `MailCodes.Place` keys.
    var pending: [String] {
        get { defaults?.stringArray(forKey: Self.pendingKey) ?? memoryPending }
        set {
            if let defaults { defaults.set(newValue, forKey: Self.pendingKey) } else { memoryPending = newValue }
        }
    }

    private var memoryPending: [String] = []
    /// Deletes a message in Messages' window, or marks an email read and archives it in Mail;
    /// throws why it couldn't. Tests give their own.
    var deleter: (String) async throws -> Void = { key in
        if let place = MailCodes.Place(key: key) {
            try await MailCodes.archive(place)
        } else {
            try await CodeTextWindow.delete(key)
        }
    }
    var isLocked: () -> Bool = { SystemScreen().isLocked() }
    /// Whether the change is still allowed when it runs: Messages (a message) or Mail (an email)
    /// still Read & write in Latchkey's settings (security review 2026-11-22: a delete queued while
    /// locked must not outlive the Owner turning the capability down). Set by the app; true in tests.
    var mayDo: (String) -> Bool = { _ in true }
    private var deleting = false

    /// How a cleanup went.
    enum Outcome: Equatable {
        case done
        case atUnlock
        case failed(String)
    }

    /// Deletes the message, or archives the email, `key` names: now while unlocked, else at the
    /// next unlock.
    func request(_ key: String) async -> Outcome {
        guard !isLocked() else {
            if !pending.contains(key) { pending.append(key) }
            return .atUnlock
        }
        do {
            try await deleter(key)
            record(key, nil)
            return .done
        } catch {
            let why = Self.why(error, email: MailCodes.Place(key: key) != nil)
            record(key, why)
            return .failed(why)
        }
    }

    /// Everything waiting, while the Mac is unlocked (at start and at each unlock).
    func deletePending() async {
        guard !deleting, !pending.isEmpty, !isLocked() else { return }
        deleting = true
        defer { deleting = false }
        for key in pending {
            guard mayDo(key) else {
                record(key, "it is no longer allowed in Latchkey's settings")
                pending.removeAll { $0 == key }
                continue
            }
            do {
                try await deleter(key)
                record(key, nil)
            } catch {
                record(key, Self.why(error, email: MailCodes.Place(key: key) != nil))
            }
            pending.removeAll { $0 == key }
        }
    }

    private func record(_ key: String, _ why: String?) {
        let email = MailCodes.Place(key: key) != nil
        if let why {
            EventLog.shared.record(
                .app,
                "\(email ? "An email stays in Mail" : "A message stays in Messages") (Claude asked to \(email ? "archive" : "delete") it): \(why)",
                error: true)
        } else {
            EventLog.shared.record(
                .app,
                email
                    ? "Marked an email read and archived it in Mail, as Claude asked"
                    : "Deleted a message in Messages, as Claude asked")
        }
    }

    static func why(_ error: Error, email: Bool) -> String {
        (error as? CodeTextWindow.Problem)?.message
            ?? (error as? ScriptError).map { e -> String in
                guard email else { return MessagesCapability.explain(e) }
                if case .notAllowed = e {
                    return
                        "Latchkey isn't allowed to control Mail. The Mac's owner can allow it in Latchkey's Settings → Permissions."
                }
                return MessagesCapability.explain(e).replacingOccurrences(of: "Messages", with: "Mail")
            } ?? "\(error)"
    }
}

/// Deleting one message in Messages' own window, in the background (spec 002 FR-180, was spec 013
/// FR-1362; the way spec 002's research found, 2026-11-05): show its conversation at the message without bringing
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
        let balloon: AXUIElement
        do {
            balloon = try await wait("the message") { () -> AXUIElement? in
                let hits = balloons().filter { !$0.fromMe && $0.text == located.text }
                return hits.count == 1 ? hits[0].element : nil
            }
        } catch {
            // What the window showed instead, without any text (two Uber code texts, 2026-11-22,
            // 0.8.223: never found; the next failure says why).
            throw Problem(message: "Messages' window didn't show the message (\(seen(located.text)))")
        }
        guard performNamed(balloon, "Delete…") else { throw Problem(message: "Messages doesn't offer deleting it") }
        try await confirmSheet()
        _ = try await wait("Messages to delete it", seconds: 10) { () -> Bool? in
            do { return try store.locate(guid) == nil ? true : nil } catch { return nil }
        }
    }

    /// What the transcript shows, for the error: how many messages, how many from others, how
    /// many with exactly the text, and the nearest one's length and start, never their text.
    static func seen(_ text: String) -> String {
        let all = balloons()
        let theirs = all.filter { !$0.fromMe }
        let same = theirs.filter { $0.text == text }.count
        let head = String(text.prefix(12))
        let near = theirs.filter { $0.text.hasPrefix(head) }
        let lengths = near.map { String($0.text.count) }.joined(separator: ", ")
        return
            "it shows \(all.count) messages, \(theirs.count) from others, \(same) with exactly its text, \(near.count) starting like it (lengths \(lengths.isEmpty ? "none" : lengths); the message's is \(text.count))"
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
