import AppKit
import ApplicationServices
import os

/// What Latchkey does in Messages' own window, through Accessibility, in the background (spec 002
/// plan D3b, FR-172 to FR-178): tapbacks, inline replies, editing, unsending, deleting, and new
/// groups, which Messages' scripting can't do (its dictionary has only `send`).
protocol MessagesUI: Sendable {
    /// Why the window can't be used now (the Mac locked, Accessibility not allowed), or nil.
    func unavailable() -> String?
    /// Does `op` to the message the window shows for `target`.
    func act(_ op: MessageOp, on target: BalloonTarget) async throws
    /// Deletes `conversation`, shown by `message` (its newest), once the window shows it.
    func deleteConversation(_ conversation: ConversationIdentity, showing message: String) async throws
    /// Starts a group with these numbers and addresses and sends `text` to it.
    func startGroup(_ handles: [String], text: String) async throws
    /// Names the group `conversation`, shown by `message`, once the window shows it.
    func nameGroup(_ conversation: ConversationIdentity, showing message: String, name: String) async throws
}

/// What the window must show before anything is pressed: the conversation's name, or its
/// people's names and numbers (security review 2026-11-05: never act on whatever is shown).
struct ConversationIdentity: Sendable, Equatable {
    var id: String
    /// The group's own name, if it has one.
    var name: String?
    var participants: [MessagesStore.Participant]
}

/// How to find one message in the window: Messages shows no ids there, so by its conversation,
/// its text (or file name), and its side. Only a single match is acted on.
struct BalloonTarget: Sendable, Equatable {
    var message: String
    var text: String
    var attachmentNames: [String] = []
    var fromMe: Bool
    /// Later messages in the conversation on the same side that read the same.
    var laterSame: Int = 0
    var conversation: ConversationIdentity
}

enum Tapback: String, Sendable, CaseIterable {
    case love, like, dislike, laugh, emphasize, question

    /// The tapback picker's buttons, by identifier (the same in every language).
    var button: String {
        switch self {
        case .love: "heart"
        case .like: "thumbsUp"
        case .dislike: "thumbsDown"
        case .laugh: "ha"
        case .emphasize: "exclamation"
        case .question: "questionMark"
        }
    }

    /// `associated_message_type` of the tapback; + 1000 takes it back.
    var code: Int {
        switch self {
        case .love: 2000
        case .like: 2001
        case .dislike: 2002
        case .laugh: 2003
        case .emphasize: 2004
        case .question: 2005
        }
    }

    var kind: MessagesStore.Reaction.Kind {
        switch self {
        case .love: .love
        case .like: .like
        case .dislike: .dislike
        case .laugh: .laugh
        case .emphasize: .emphasize
        case .question: .question
        }
    }
}

enum MessageOp: Sendable, Equatable {
    /// Pressing a tapback the message already has from the Mac's owner takes it back.
    case tapback(Tapback)
    case reply(String)
    case edit(String)
    case unsend
    case delete
}

/// Why something in the window couldn't be done, said plainly to Claude.
struct MessagesWindowProblem: Error, Equatable {
    var message: String
}

/// Messages' window on this Mac.
struct LiveMessagesUI: MessagesUI {
    static let bundleID = "com.apple.MobileSMS"

    func unavailable() -> String? {
        if SystemScreen().isLocked() {
            return
                "The Mac is locked, and while it is Messages' window can't be used (macOS hides it from other apps), so this can't be done until someone unlocks the Mac. Sending text and files to a person or an existing conversation still works."
        }
        if !AXIsProcessTrusted() {
            return
                "Latchkey isn't allowed to use Accessibility, which it needs to do this in Messages' window. The Mac's owner can allow it in Latchkey's Settings → Permissions."
        }
        return nil
    }

    func act(_ op: MessageOp, on target: BalloonTarget) async throws {
        if target.laterSame > 0 { throw problem(MessagesAX.ambiguous) }
        try await show(message: target.message, in: target.conversation)
        let balloon = try await find(target)
        switch op {
        case .tapback(let t):
            try perform(balloon, MessagesAX.Action.tapback)
            let button = try await MessagesAX.wait("the tapback choices") { MessagesAX.element(id: t.button) }
            // The picker animates in; a press before it settles is taken as done and dropped
            // (live check 2026-11-06). Pressed once only: a second press would take it back.
            try await MessagesAX.settled(button)
            guard MessagesAX.press(button) else { throw problem("Messages didn't take the tapback.") }
            do {
                _ = try await MessagesAX.wait("the tapback taken", seconds: 3) {
                    MessagesAX.element(id: MessagesAX.tapbackPicker) == nil ? true : nil
                }
            } catch {
                throw problem("Messages didn't take the tapback; its choices stayed open.")
            }
        case .reply(let text):
            try perform(balloon, MessagesAX.Action.reply)
            // Only into the replies view's field: never the conversation's own (that would send
            // the text as an ordinary message).
            let replies = try await MessagesAX.wait("the replies view") { MessagesAX.repliesView() }
            try await MessagesAX.sendTyped(text, in: replies)
            MessagesAX.closeReplies()
        case .edit(let text):
            try perform(balloon, MessagesAX.Action.edit, unavailable: Self.editLimit)
            try await MessagesAX.typeIntoEditor(text, replacing: target.text)
        case .unsend:
            try perform(balloon, MessagesAX.Action.unsend, unavailable: Self.unsendLimit)
        case .delete:
            try perform(balloon, MessagesAX.Action.delete)
            try await MessagesAX.confirmSheet()
        }
    }

    static let editLimit =
        "Messages doesn't offer editing this message: it allows editing only iMessages, within 15 minutes of sending, up to five times."
    static let unsendLimit =
        "Messages doesn't offer unsending this message: it allows unsending only iMessages, within 2 minutes of sending."

    func deleteConversation(_ conversation: ConversationIdentity, showing message: String) async throws {
        try await show(message: message, in: conversation)
        let row = try await MessagesAX.wait("the conversation in the list") { MessagesAX.selectedConversationRow() }
        // The row itself must name the conversation too.
        guard MessagesAX.rowNames(MessagesAX.string(row, kAXDescriptionAttribute) ?? "", conversation) else {
            throw problem(MessagesAX.otherConversation)
        }
        guard MessagesAX.performNamed(row, MessagesAX.Action.delete) else {
            throw problem("Messages doesn't offer deleting this conversation.")
        }
        try await MessagesAX.confirmSheet()
    }

    func startGroup(_ handles: [String], text: String) async throws {
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "addresses", value: handles.joined(separator: ","))]
        guard let url = parts.url else { throw problem("Those numbers and addresses can't be put in a link.") }
        try await MessagesAX.open(url)
        try await MessagesAX.waitForRecipients(handles.count)
        try await MessagesAX.sendTyped(text, in: nil)
    }

    func nameGroup(_ conversation: ConversationIdentity, showing message: String, name: String) async throws {
        try await show(message: message, in: conversation)
        try await MessagesAX.setGroupName(name)
    }

    /// Shows the conversation with this message, scrolled to it, without bringing Messages
    /// forward, and checks the window shows that conversation.
    func show(message: String, in conversation: ConversationIdentity) async throws {
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "message-guid", value: message)]
        guard let url = parts.url else { throw problem("That message id can't be shown.") }
        MessagesAX.closeReplies()
        try await MessagesAX.open(url)
        do {
            _ = try await MessagesAX.wait("the conversation") {
                MessagesAX.shows(conversation) ? true : nil
            }
        } catch {
            throw problem(MessagesAX.otherConversation)
        }
    }

    private func find(_ target: BalloonTarget) async throws -> AXUIElement {
        var last: [MessagesAX.Balloon] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            last = MessagesAX.balloons()
            if let i = MessagesAX.pick(target, in: last.map(\.shown)) { return last[i].element }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if last.filter({ MessagesAX.matches(target, $0.shown) }).count > 1 { throw problem(MessagesAX.ambiguous) }
        throw problem(
            "Messages' window didn't show this message, so nothing was changed. If it's old, it may not be loaded in the window."
        )
    }

    private func perform(_ balloon: AXUIElement, _ action: String, unavailable: String? = nil) throws {
        guard MessagesAX.performNamed(balloon, action) else {
            throw problem(unavailable ?? "Messages doesn't offer \(action) for this message.")
        }
    }

    private func problem(_ s: String) -> MessagesWindowProblem { MessagesWindowProblem(message: s) }
}

/// Accessibility lookups in Messages' window. Messages names its message actions in the Mac's
/// language and English is matched (research "Messages' window"); the tapback buttons, the
/// entry field, and the lists are found by identifier.
enum MessagesAX {
    enum Action {
        static let tapback = "Tapback Details…"
        static let reply = "Reply…"
        static let edit = "Edit"
        static let unsend = "Undo Send"
        static let delete = "Delete…"
    }

    struct Balloon {
        var element: AXUIElement
        var shown: Shown
    }

    /// What the window shows of one message.
    struct Shown: Sendable, Equatable {
        /// The message's text, or its description (attachments) when it has no text.
        var text: String
        var description: String
        var fromMe: Bool
    }

    static let ambiguous =
        "Messages' window shows more than one message that reads the same on that side of the conversation, and it shows no ids, so Latchkey can't tell which one is meant. Nothing was changed."
    static let otherConversation =
        "Messages' window didn't show that conversation (its title or people didn't match), so nothing was changed."

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: LiveMessagesUI.bundleID).first
    }

    static func application() -> AXUIElement? {
        guard let app = app() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        return ax
    }

    /// Opens a Messages link without bringing Messages forward, and waits for its window.
    static func open(_ url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        guard let messages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LiveMessagesUI.bundleID)
        else { throw MessagesWindowProblem(message: "Messages isn't on this Mac.") }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: messages, configuration: config)
        _ = try await wait("Messages' window") { window() }
        try? await Task.sleep(for: .milliseconds(400))  // the transcript scrolls to the message
    }

    static func window() -> AXUIElement? {
        guard let app = application() else { return nil }
        return children(app, kAXWindowsAttribute).first {
            MessagesAX.string($0, kAXIdentifierAttribute) == "SceneWindow"
        }
            ?? children(app, kAXWindowsAttribute).first { MessagesAX.string($0, kAXRoleAttribute) == "AXWindow" }
    }

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

    static func element(id: String) -> AXUIElement? {
        guard let w = window() else { return nil }
        return first(in: w) { MessagesAX.string($0, kAXIdentifierAttribute) == id }
    }

    /// The conversation's transcript, never the replies view's.
    static func transcript() -> AXUIElement? {
        guard let w = window() else { return nil }
        return first(in: w) {
            MessagesAX.string($0, kAXIdentifierAttribute) == "TranscriptCollectionView"
                && MessagesAX.string($0, kAXDescriptionAttribute) != "Reply transcript"
        }
    }

    /// The messages shown, top to bottom. A message is the element with identifier "Sticker"
    /// (a group, button, or link); its text is its `CKBalloonTextView`'s value; Messages shows
    /// the Mac owner's on the right.
    static func balloons() -> [Balloon] {
        guard let t = transcript() else { return [] }
        let middle = frame(t).map { $0.midX } ?? 0
        var list: [AXUIElement] = []
        all(in: t, { MessagesAX.string($0, kAXIdentifierAttribute) == "Sticker" }, into: &list)
        return list.map { e in
            // macOS 27 gives the message's own text as its input label (its description adds
            // "Your iMessage, " and the time); earlier versions had a CKBalloonTextView inside.
            let text =
                inputLabel(e)
                ?? first(in: e) { MessagesAX.string($0, kAXIdentifierAttribute) == "CKBalloonTextView" }
                .flatMap { MessagesAX.string($0, kAXValueAttribute) }
            let description = MessagesAX.string(e, kAXDescriptionAttribute) ?? ""
            return Balloon(
                element: e,
                shown: Shown(
                    text: text ?? description, description: description,
                    fromMe: (frame(e).map { $0.midX } ?? 0) > middle))
        }
    }

    /// The message's text as Messages labels it for input (`AXUserInputLabels`), when it has one.
    static func inputLabel(_ e: AXUIElement) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, "AXUserInputLabels" as CFString, &v) == .success,
            let labels = v as? [String], labels.count == 1, !labels[0].isEmpty
        else { return nil }
        return labels[0]
    }

    static func matches(_ target: BalloonTarget, _ b: Shown) -> Bool {
        guard b.fromMe == target.fromMe else { return false }
        let wanted = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { return b.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
        return target.attachmentNames.contains { !$0.isEmpty && b.description.contains($0) }
    }

    /// The one message shown that matches; none when no message or several do.
    static func pick(_ target: BalloonTarget, in list: [Shown]) -> Int? {
        let hits = list.indices.filter { matches(target, list[$0]) }
        return hits.count == 1 && target.laterSame == 0 ? hits[0] : nil
    }

    /// Whether the window's title names this conversation: the group's name, or each of its
    /// people (by name from Contacts, or by number or address) and no one else.
    static func shows(_ c: ConversationIdentity) -> Bool {
        guard let w = window(), let title = string(w, kAXTitleAttribute) else { return false }
        return titleNames(title, c)
    }

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

    /// A conversation list row's description starts with the conversation's title ("Name, last
    /// message, time").
    static func rowNames(_ description: String, _ c: ConversationIdentity) -> Bool {
        if let name = c.name, !name.isEmpty {
            return description == name || description.hasPrefix(name + ",")
        }
        // The title is everything before the first ", " that isn't inside the names themselves:
        // try each cut.
        var cut = description.startIndex
        while let r = description.range(of: ", ", range: cut..<description.endIndex) {
            if titleNames(String(description[..<r.lowerBound]), c) { return true }
            cut = r.upperBound
        }
        return titleNames(description, c)
    }

    static func names(_ part: String, _ p: MessagesStore.Participant) -> Bool {
        if let name = p.name, part == name { return true }
        if p.handle.contains("@") { return part.caseInsensitiveCompare(p.handle) == .orderedSame }
        let a = part.filter(\.isASCII).filter(\.isNumber)
        let b = p.handle.filter(\.isASCII).filter(\.isNumber)
        return a.count >= 7 && b.count >= 7 && (a.hasSuffix(b) || b.hasSuffix(a))
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

    /// Performs a custom action ("Reply…") by its name, or a standard one ("AXPress").
    static func performNamed(_ e: AXUIElement, _ name: String) -> Bool {
        var v: CFArray?
        guard AXUIElementCopyActionNames(e, &v) == .success, let names = v as? [String] else { return false }
        guard let action = names.first(where: { $0 == name || $0.hasPrefix("Name:\(name)\n") }) else { return false }
        return AXUIElementPerformAction(e, action as CFString) == .success
    }

    static func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }

    static let tapbackPicker = "TapbackPickerCollectionView"

    /// Waits until the element stops moving: the same frame on three looks 100 ms apart.
    static func settled(_ e: AXUIElement) async throws {
        var last = frame(e)
        var same = 0
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let now = frame(e)
            same = (now != nil && now == last) ? same + 1 : 0
            if same >= 2 { return }
            last = now
        }
    }

    /// A text or number attribute, as text.
    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func wait<T>(_ what: String, seconds: Double = 5, _ look: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let hit = look() { return hit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw MessagesWindowProblem(message: "Messages' window didn't show \(what) in time, so nothing more was done.")
    }

    /// Puts text in the entry field and presses Return, sent to Messages alone. With `replies`,
    /// only the field that belongs with that replies view.
    static func sendTyped(_ text: String, in replies: AXUIElement?) async throws {
        let field = try await wait("the message field") { () -> AXUIElement? in
            guard let replies else { return element(id: "messageBodyField") }
            return replyField(replies)
        }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw MessagesWindowProblem(message: "Messages' message field didn't take the text; nothing was sent.")
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressReturn()
        // The field empties once Messages has taken the message.
        _ = try await wait("the message as sent") {
            (MessagesAX.string(field, kAXValueAttribute) ?? "").isEmpty ? true : nil
        }
    }

    static func pressReturn() {
        guard let pid = app()?.processIdentifier else { return }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)?.postToPid(pid)
        }
    }

    /// While a message is being edited, its text is a focused field holding the old text (macOS 27:
    /// a text field inside the message; earlier, its CKBalloonTextView): replaced, then Return. If
    /// the editor doesn't close, the edit is cancelled and reported.
    static func typeIntoEditor(_ text: String, replacing old: String) async throws {
        let wanted = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let editor = try await wait("the message being edited") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return first(in: w) {
                MessagesAX.string($0, kAXFocusedAttribute) == "1"
                    && (MessagesAX.string($0, kAXIdentifierAttribute) == "CKBalloonTextView"
                        || MessagesAX.string($0, kAXRoleAttribute) == "AXTextField")
                    && MessagesAX.string($0, kAXIdentifierAttribute) != "messageBodyField"
                    && (MessagesAX.string($0, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        == wanted
            }
        }
        guard AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, text as CFString) == .success else {
            cancelEdit()
            throw MessagesWindowProblem(message: "Messages didn't take the new text; the message wasn't changed.")
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressReturn()
        do {
            _ = try await wait("the edit sent", seconds: 3) { () -> Bool? in
                var v: AnyObject?
                // The field leaves the window once Messages has taken the edit.
                return AXUIElementCopyAttributeValue(editor, kAXRoleAttribute as CFString, &v) != .success
                    || MessagesAX.string(editor, kAXFocusedAttribute) != "1" ? true : nil
            }
        } catch {
            cancelEdit()
            throw MessagesWindowProblem(
                message: "Messages didn't take the edit, so it was cancelled; the message wasn't changed.")
        }
    }

    /// Escape, sent to Messages alone: leaves editing without changing the message.
    static func cancelEdit() {
        guard let pid = app()?.processIdentifier else { return }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.postToPid(pid)
        }
    }

    /// Presses the button of Messages' question ("Delete from all your devices?") that isn't Cancel.
    static func confirmSheet() async throws {
        let sheet = try await wait("its question") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return children(w).first { MessagesAX.string($0, kAXRoleAttribute) == "AXSheet" }
        }
        var cancel: AnyObject?
        AXUIElementCopyAttributeValue(sheet, kAXCancelButtonAttribute as CFString, &cancel)
        let buttons = children(sheet).filter { MessagesAX.string($0, kAXRoleAttribute) == "AXButton" }
        guard
            let yes = buttons.last(where: { b in
                cancel.map { !CFEqual($0, b) } ?? (MessagesAX.string(b, kAXTitleAttribute) != "Cancel")
            }), press(yes)
        else { throw MessagesWindowProblem(message: "Messages asked something Latchkey couldn't answer.") }
    }

    /// The replies view's transcript, while it shows (Messages describes it "Reply transcript").
    static func repliesView() -> AXUIElement? {
        guard let w = window() else { return nil }
        return first(in: w) {
            MessagesAX.string($0, kAXIdentifierAttribute) == "TranscriptCollectionView"
                && MessagesAX.string($0, kAXDescriptionAttribute) == "Reply transcript"
        }
    }

    /// The entry field beside the replies view: in the same container.
    static func replyField(_ replies: AXUIElement) -> AXUIElement? {
        guard let box = parent(replies) else { return nil }
        return first(in: box) { MessagesAX.string($0, kAXIdentifierAttribute) == "messageBodyField" }
    }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        var p: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &p) == .success, let p,
            CFGetTypeID(p) == AXUIElementGetTypeID()
        else { return nil }
        return (p as! AXUIElement)
    }

    /// Leaves the replies view, if it shows.
    static func closeReplies() {
        guard let replies = repliesView() else { return }
        _ = AXUIElementPerformAction(replies, kAXCancelAction as CFString)
    }

    /// The conversation list's row for the conversation shown.
    static func selectedConversationRow() -> AXUIElement? {
        guard let list = element(id: "ConversationList") else { return nil }
        return children(list).first { MessagesAX.string($0, kAXSelectedAttribute) == "1" }
    }

    /// Waits until a new conversation's recipients are in place.
    static func waitForRecipients(_ count: Int) async throws {
        _ = try await wait("the new conversation") { element(id: "messageBodyField") }
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The conversation's details (its title's "Conversation Details"), the toolbar's Edit menu,
    /// "Edit Name & Photo" (found by identifier), the sheet's name field, Done (research
    /// "Messages' window", live 2026-11-06). Whatever was opened is closed again, also on failure.
    static func setGroupName(_ name: String) async throws {
        guard let title = element(id: "ConversationTitle") else {
            throw MessagesWindowProblem(message: "Messages didn't show the group's details.")
        }
        let wasOpen = element(id: detailsHeader) != nil
        if !wasOpen {
            guard performNamed(title, "Conversation Details") || press(title) else {
                throw MessagesWindowProblem(message: "Messages didn't show the group's details.")
            }
        }
        defer {
            if !wasOpen, element(id: detailsHeader) != nil, let t = element(id: "ConversationTitle") {
                _ = performNamed(t, "Conversation Details") || press(t)
            }
        }
        _ = try await wait("the group's details") { element(id: detailsHeader) }
        let item = try await nameMenuItem()
        guard press(item) else {
            cancelEdit()
            throw MessagesWindowProblem(message: "Messages didn't open the group's name.")
        }
        let sheet = try await wait("the group's name") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return children(w).first {
                MessagesAX.string($0, kAXRoleAttribute) == "AXSheet"
                    && first(in: $0) { MessagesAX.string($0, kAXRoleAttribute) == "AXTextField" } != nil
            }
        }
        guard let field = first(in: sheet, { MessagesAX.string($0, kAXRoleAttribute) == "AXTextField" }),
            let (cancel, done) = sheetButtons(sheet)
        else {
            cancelEdit()
            throw MessagesWindowProblem(message: "Messages' group name editor wasn't as expected; nothing was changed.")
        }
        // The name field takes focus and text only while Messages is in front; Done enables only on
        // typed text (a value set through Accessibility leaves it off); and a sheet left changed asks
        // "discard your changes?" on Cancel (live 2026-11-06). So Messages comes forward for a
        // moment, only while the Owner isn't using the Mac (FR-179); the name is typed, Done is
        // pressed only once it is on and the field holds the name, and on any failure the old text
        // is typed back before Cancel, all while Messages is still in front.
        guard let messages = app() else { throw MessagesWindowProblem(message: "Messages isn't running.") }
        var saved = false
        let outcome = await Foreground.run(
            messages, log: { line, error in groupLog.log("\(line, privacy: .public) \(error)") }
        ) {
            ownerActed in
            let old = string(field, kAXValueAttribute) ?? ""
            // The field takes focus a moment after Messages comes forward; keys before that are
            // lost (live 2026-11-07: "LK probe" became "probe"). So focus is asked for until it
            // holds, and the name is typed again (over all of it) if the field doesn't hold it.
            _ = try? await wait("the name field focused", seconds: 1.5) { () -> Bool? in
                if string(field, kAXFocusedAttribute) == "1" { return true }
                _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return nil
            }
            var ready: Bool?
            for _ in 0..<2 where ready == nil && !ownerActed() {
                await replaceTyped(in: field, with: name)
                ready = try? await wait("the name typed", seconds: 1.5) { () -> Bool? in
                    string(field, kAXValueAttribute) == name && string(done, kAXEnabledAttribute) == "1" ? true : nil
                }
            }
            guard ready != nil, !ownerActed(), press(done) else {
                await replaceTyped(in: field, with: old)
                try? await Task.sleep(for: .milliseconds(300))
                _ = press(cancel)
                await discardNameSheet()
                return false
            }
            saved =
                (try? await wait("the name saved", seconds: 3) { () -> Bool? in
                    guard let w = window() else { return true }
                    return children(w).contains { MessagesAX.string($0, kAXRoleAttribute) == "AXSheet" } ? nil : true
                }) != nil
            return saved
        }
        // No name sheet is left open behind the Owner's app: one left (Messages not brought
        // forward, or the Owner acted) is closed with Messages in front again, unsaved. Its
        // buttons answer only then (live 2026-11-06).
        if !saved, nameSheet() != nil {
            _ = await Foreground.run(
                messages, log: { line, error in groupLog.log("\(line, privacy: .public) \(error)") }
            ) { _ in
                await discardNameSheet()
                return nameSheet() == nil
            }
        }
        if nameSheet() != nil {
            throw MessagesWindowProblem(
                message:
                    "The group wasn't named, and Messages' name editor is still open in the group's window; nothing was saved."
            )
        }
        switch outcome {
        case .done: return
        case .ownerBusy:
            throw MessagesWindowProblem(
                message:
                    "The group wasn't named: someone was using the Mac, and naming needs Messages in front for a moment. Try again shortly."
            )
        case .ownerActed:
            throw MessagesWindowProblem(
                message:
                    "The group wasn't named: someone typed or clicked while Messages was in front, so Latchkey stopped."
            )
        case .notForward:
            throw MessagesWindowProblem(message: "The group wasn't named: Messages couldn't be brought forward for it.")
        case .failed:
            throw MessagesWindowProblem(message: "Messages didn't take the group's name; nothing was changed.")
        }
    }

    static let groupLog = Logger(subsystem: "net.melisma.latchkey", category: "messages")

    /// The window's sheet, if one is open (the name editor, or Messages' question over it).
    static func nameSheet() -> AXUIElement? {
        guard let w = window() else { return nil }
        return children(w).first { MessagesAX.string($0, kAXRoleAttribute) == "AXSheet" }
    }

    /// Closes the name editor without saving, while Messages is in front: Cancel, and when
    /// Messages asks "discard your changes?", Discard Changes (the alert's button by its title,
    /// the one Messages shows in every language being unknown, else the alert's first button).
    static func discardNameSheet() async {
        for _ in 0..<3 {
            guard let sheet = nameSheet() else { return }
            if let alert = first(in: sheet, { MessagesAX.string($0, kAXDescriptionAttribute) == "alert" }) {
                let buttons = children(alert).filter { MessagesAX.string($0, kAXRoleAttribute) == "AXButton" }
                if let discard = discardButton(buttons.map { MessagesAX.string($0, kAXTitleAttribute) ?? "" }) {
                    _ = press(buttons[discard])
                }
            } else if let (cancel, _) = sheetButtons(sheet) {
                _ = press(cancel)
            }
            _ = try? await wait("the name editor closed", seconds: 1) { nameSheet() == nil ? true : nil }
        }
    }

    /// Which of the discard question's buttons discards: "Discard Changes" by title, else the
    /// first button (Messages puts Discard Changes before Cancel), never one titled Cancel.
    static func discardButton(_ titles: [String]) -> Int? {
        if let i = titles.firstIndex(where: { $0.localizedCaseInsensitiveContains("discard") }) { return i }
        guard let first = titles.indices.first, titles[first] != "Cancel" else { return nil }
        return first
    }

    /// Selects all of a focused field's text and types `text` over it as key presses sent to
    /// Messages alone (never to the app in front); typing nothing deletes the selection.
    static func replaceTyped(in field: AXUIElement, with text: String) async {
        guard let pid = app()?.processIdentifier else { return }
        let length = (string(field, kAXValueAttribute) ?? "").utf16.count
        var range = CFRange(location: 0, length: length)
        if let all = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, all)
        }
        let src = CGEventSource(stateID: .privateState)
        if text.isEmpty, length > 0 {
            for down in [true, false] {
                CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down)?.postToPid(pid)
            }
            return
        }
        // One key press per character, so an emoji's two halves arrive together.
        for character in text {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                e?.postToPid(pid)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    static let detailsHeader = "DetailsHeaderTitle"
    static let nameItem = "edit_name_&_photo"

    /// The details' Edit menu is the toolbar's rightmost menu button while the details show; it is
    /// opened and must hold "Edit Name & Photo", or it is closed again and nothing else is done.
    static func nameMenuItem() async throws -> AXUIElement {
        guard let w = window(), let toolbar = first(in: w, { MessagesAX.string($0, kAXRoleAttribute) == "AXToolbar" })
        else { throw MessagesWindowProblem(message: "Messages didn't show its toolbar.") }
        let buttons = children(toolbar).filter { MessagesAX.string($0, kAXRoleAttribute) == "AXMenuButton" }
        guard let edit = buttons.max(by: { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }), press(edit) else {
            throw MessagesWindowProblem(message: "Messages didn't offer editing the group.")
        }
        do {
            return try await wait("the group's Edit menu", seconds: 2) {
                first(in: edit) { MessagesAX.string($0, kAXIdentifierAttribute) == nameItem }
            }
        } catch {
            cancelEdit()
            throw MessagesWindowProblem(message: "Messages didn't offer naming the group; nothing was changed.")
        }
    }

    /// A sheet's two buttons side by side at its bottom (Cancel, Done): the pair of buttons that
    /// are a container's only children, left one first.
    static func sheetButtons(_ sheet: AXUIElement) -> (AXUIElement, AXUIElement)? {
        var groups: [AXUIElement] = []
        all(
            in: sheet,
            {
                let c = MessagesAX.children($0)
                return c.count == 2 && c.allSatisfy { MessagesAX.string($0, kAXRoleAttribute) == "AXButton" }
            }, into: &groups)
        guard groups.count == 1 else { return nil }
        let pair = children(groups[0]).sorted { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }
        return (pair[0], pair[1])
    }
}
