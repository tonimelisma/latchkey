import AppKit
import ApplicationServices

/// What Latchkey does in Messages' own window, through Accessibility, in the background (spec 002
/// plan D3b, FR-172 to FR-178): tapbacks, inline replies, editing, unsending, deleting, and new
/// groups, which Messages' scripting can't do (its dictionary has only `send`).
protocol MessagesUI: Sendable {
    /// Why the window can't be used now (the Mac locked, Accessibility not allowed), or nil.
    func unavailable() -> String?
    /// Does `op` to the message the window shows for `target`.
    func act(_ op: MessageOp, on target: BalloonTarget) async throws
    /// Deletes the conversation that `message` (its newest) is in.
    func deleteConversation(showing message: String) async throws
    /// Starts a group with these numbers and addresses and sends `text` to it.
    func startGroup(_ handles: [String], text: String) async throws
    /// Names the group that `message` is in.
    func nameGroup(showing message: String, name: String) async throws
}

/// How to find one message in the window: Messages shows no ids there, so by its text (or file
/// name), its side, and how many later messages on that side read the same.
struct BalloonTarget: Sendable, Equatable {
    var message: String
    var text: String
    var attachmentNames: [String] = []
    var fromMe: Bool
    var laterSame: Int = 0
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
        try await show(message: target.message)
        let balloon = try await find(target)
        switch op {
        case .tapback(let t):
            try perform(balloon, MessagesAX.Action.tapback)
            let button = try await MessagesAX.wait("the tapback choices") { MessagesAX.element(id: t.button) }
            guard MessagesAX.press(button) else { throw problem("Messages didn't take the tapback.") }
        case .reply(let text):
            try perform(balloon, MessagesAX.Action.reply)
            try await MessagesAX.sendTyped(text)
            MessagesAX.closeReplies()
        case .edit(let text):
            try perform(balloon, MessagesAX.Action.edit, unavailable: Self.editLimit)
            try await MessagesAX.typeIntoEditor(text)
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

    func deleteConversation(showing message: String) async throws {
        try await show(message: message)
        let row = try await MessagesAX.wait("the conversation in the list") { MessagesAX.selectedConversationRow() }
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
        try await MessagesAX.sendTyped(text)
    }

    func nameGroup(showing message: String, name: String) async throws {
        try await show(message: message)
        try await MessagesAX.setGroupName(name)
    }

    /// Shows the conversation with this message, scrolled to it, without bringing Messages forward.
    func show(message: String) async throws {
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "message-guid", value: message)]
        guard let url = parts.url else { throw problem("That message id can't be shown.") }
        MessagesAX.closeReplies()
        try await MessagesAX.open(url)
    }

    private func find(_ target: BalloonTarget) async throws -> AXUIElement {
        var last: [MessagesAX.Balloon] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            last = MessagesAX.balloons()
            if let hit = MessagesAX.pick(target, in: last) { return hit }
            try? await Task.sleep(for: .milliseconds(150))
        }
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
        /// The message's text, or its description (attachments) when it has no text.
        var text: String
        var description: String
        var fromMe: Bool
    }

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
        return children(app, kAXWindowsAttribute).first { AppWindowReader.string($0, kAXIdentifierAttribute) == "SceneWindow" }
            ?? children(app, kAXWindowsAttribute).first { AppWindowReader.string($0, kAXRoleAttribute) == "AXWindow" }
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
        return first(in: w) { AppWindowReader.string($0, kAXIdentifierAttribute) == id }
    }

    /// The main transcript (not the replies one, which comes first while it is open).
    static func transcript() -> AXUIElement? {
        guard let w = window() else { return nil }
        var list: [AXUIElement] = []
        all(in: w, { AppWindowReader.string($0, kAXIdentifierAttribute) == "TranscriptCollectionView" }, into: &list)
        return list.last
    }

    /// The messages shown, top to bottom. A message is the element with identifier "Sticker"
    /// (a group, button, or link); its text is its `CKBalloonTextView`'s value; Messages shows
    /// the Mac owner's on the right.
    static func balloons() -> [Balloon] {
        guard let t = transcript() else { return [] }
        let middle = frame(t).map { $0.midX } ?? 0
        var list: [AXUIElement] = []
        all(in: t, { AppWindowReader.string($0, kAXIdentifierAttribute) == "Sticker" }, into: &list)
        return list.map { e in
            let text = first(in: e) { AppWindowReader.string($0, kAXIdentifierAttribute) == "CKBalloonTextView" }
                .flatMap { AppWindowReader.string($0, kAXValueAttribute) }
            let description = AppWindowReader.string(e, kAXDescriptionAttribute) ?? ""
            return Balloon(
                element: e, text: text ?? description, description: description,
                fromMe: (frame(e).map { $0.midX } ?? 0) > middle)
        }
    }

    static func matches(_ target: BalloonTarget, _ b: Balloon) -> Bool {
        guard b.fromMe == target.fromMe else { return false }
        let wanted = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { return b.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
        return target.attachmentNames.contains { !$0.isEmpty && b.description.contains($0) }
    }

    /// The matching message, counting from the bottom past the later ones that read the same
    /// (the window shows a run of messages in order, around the one asked for).
    static func pick(_ target: BalloonTarget, in list: [Balloon]) -> AXUIElement? {
        let same = list.filter { matches(target, $0) }
        guard same.count > target.laterSame else { return nil }
        return same[same.count - 1 - target.laterSame].element
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

    static func wait<T>(_ what: String, seconds: Double = 5, _ look: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let hit = look() { return hit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw MessagesWindowProblem(message: "Messages' window didn't show \(what) in time, so nothing more was done.")
    }

    /// Puts text in the entry field (the reply one while replies show) and presses Return, sent
    /// to Messages alone.
    static func sendTyped(_ text: String) async throws {
        let field = try await wait("the message field") { element(id: "messageBodyField") }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw MessagesWindowProblem(message: "Messages' message field didn't take the text; nothing was sent.")
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressReturn()
        // The field empties once Messages has taken the message.
        _ = try await wait("the message as sent") {
            (AppWindowReader.string(field, kAXValueAttribute) ?? "").isEmpty ? true : nil
        }
    }

    static func pressReturn() {
        guard let pid = app()?.processIdentifier else { return }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)?.postToPid(pid)
        }
    }

    /// While a message is being edited, its text is an editable field: replaced, then Return.
    static func typeIntoEditor(_ text: String) async throws {
        let editor = try await wait("the message being edited") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return first(in: w) {
                AppWindowReader.string($0, kAXIdentifierAttribute) == "CKBalloonTextView"
                    && AppWindowReader.string($0, kAXFocusedAttribute) == "1"
            }
        }
        guard AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw MessagesWindowProblem(message: "Messages didn't take the new text; the message wasn't changed.")
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressReturn()
    }

    /// Presses the button of Messages' question ("Delete from all your devices?") that isn't Cancel.
    static func confirmSheet() async throws {
        let sheet = try await wait("its question") { () -> AXUIElement? in
            guard let w = window() else { return nil }
            return children(w).first { AppWindowReader.string($0, kAXRoleAttribute) == "AXSheet" }
        }
        var cancel: AnyObject?
        AXUIElementCopyAttributeValue(sheet, kAXCancelButtonAttribute as CFString, &cancel)
        let buttons = children(sheet).filter { AppWindowReader.string($0, kAXRoleAttribute) == "AXButton" }
        guard
            let yes = buttons.last(where: { b in
                cancel.map { !CFEqual($0, b) } ?? (AppWindowReader.string(b, kAXTitleAttribute) != "Cancel")
            }), press(yes)
        else { throw MessagesWindowProblem(message: "Messages asked something Latchkey couldn't answer.") }
    }

    /// Leaves the replies view, if it shows.
    static func closeReplies() {
        guard let w = window() else { return }
        var list: [AXUIElement] = []
        all(in: w, { AppWindowReader.string($0, kAXIdentifierAttribute) == "TranscriptCollectionView" }, into: &list)
        guard list.count > 1, let replies = list.first else { return }
        _ = AXUIElementPerformAction(replies, kAXCancelAction as CFString)
    }

    /// The conversation list's row for the conversation shown.
    static func selectedConversationRow() -> AXUIElement? {
        guard let list = element(id: "ConversationList") else { return nil }
        return children(list).first { AppWindowReader.string($0, kAXSelectedAttribute) == "1" }
    }

    /// Waits until a new conversation's recipients are in place.
    static func waitForRecipients(_ count: Int) async throws {
        _ = try await wait("the new conversation") { element(id: "messageBodyField") }
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func setGroupName(_ name: String) async throws {
        guard let title = element(id: "ConversationTitle"), performNamed(title, "Conversation Details") || press(title)
        else { throw MessagesWindowProblem(message: "Messages didn't show the group's details.") }
        throw MessagesWindowProblem(message: "Naming a group isn't done yet.")
    }
}
