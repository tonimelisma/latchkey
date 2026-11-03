import AppKit
import ApplicationServices

/// Mail's compose windows through Accessibility (plan D6; research "Compose window"). Mail comes to
/// the front only while it must (spec 008 FR-840, Toni 2026-11-02: "two short blinks"): to open
/// the window (Mail builds the message text area only for a window opened in front), to paste
/// files, and to press Send or save; each time after a pause in the Owner's typing, and the app
/// they were using comes back at once. In between the window is moved off-screen and the text is
/// typed with keys sent to Mail alone (`CGEvent.postToPid`). Fields are
/// found by Mail's own identifiers (`Mail.toField`, `popup_from`, `send`), menu items by their
/// key equivalents (⌘V, ⌘R, ⇧⌘R, ⇧⌘F, ⌘S), so a different language doesn't matter. Text and
/// recipients go in through Accessibility (the selected text set at the cursor); only files, and
/// text Mail didn't take that way, go by Edit → Paste with the clipboard lent (`ClipboardLoan`).
/// All of it works with the display off or the lid closed, but not while locked (checked live 2026-11-01:
/// sent with a file and a draft saved with the lid closed and unlocked; nothing opens while locked).
final class AXMailWindows: ComposeWindows, @unchecked Sendable {
    let pasteboard: any Pasteboard
    let scripts: any ScriptRunner
    private let lock = NSLock()
    private var previous: NSRunningApplication?

    init(scripts: any ScriptRunner, pasteboard: any Pasteboard = GeneralPasteboard()) {
        self.pasteboard = pasteboard
        self.scripts = scripts
    }

    /// Mail's scripting makes the message (new, reply, reply all, forward) and shows its window
    /// behind the Owner's apps; Mail builds its text area without coming forward (checked live
    /// 2026-11-02, unlike a window opened by a link). Answers the outgoing message's id.
    static let makeScript = """
        on run argv
        set theKind to item 1 of argv
        tell application "Mail"
        if theKind is "new" then
        set m to make new outgoing message with properties {subject:(item 2 of argv), visible:true}
        repeat with i from 3 to (count of argv) by 2
        set theField to item i of argv
        set theAddress to item (i + 1) of argv
        if theField is "to" then
        tell m to make new to recipient at end of to recipients with properties {address:theAddress}
        else if theField is "cc" then
        tell m to make new cc recipient at end of cc recipients with properties {address:theAddress}
        else
        tell m to make new bcc recipient at end of bcc recipients with properties {address:theAddress}
        end if
        end repeat
        else
        try
        set theBox to mailbox (item 3 of argv) of account id (item 2 of argv)
        on error
        set theBox to mailbox (item 3 of argv)
        end try
        set theMsg to (first message of theBox whose id is ((item 4 of argv) as integer))
        if theKind is "reply" then
        set m to reply theMsg with opening window
        else if theKind is "replyAll" then
        set m to reply theMsg with opening window and reply to all
        else
        set m to forward theMsg with opening window
        end if
        end if
        return (id of m) as text
        end tell
        end run
        """

    /// argv: the outgoing message's id, then "send", "save", "close", or "attach" and file paths.
    static let messageScript = """
        on run argv
        set theID to (item 1 of argv) as integer
        set theAction to item 2 of argv
        tell application "Mail"
        set m to first outgoing message whose id is theID
        if theAction is "send" then
        send m
        else if theAction is "save" then
        save m
        -- Mail writes the draft a moment after save; closing at once lost it (2026-11-02).
        delay 3
        close m saving no
        else if theAction is "close" then
        close m saving no
        else
        repeat with i from 3 to (count of argv)
        tell m to make new attachment with properties {file name:(POSIX file (item i of argv))} at after the last paragraph of content
        end repeat
        end if
        return "ok"
        end tell
        end run
        """

    /// The arguments for `makeScript`, or nil when this opening can't be made by scripting.
    static func makeArguments(_ how: ComposeOpening) -> [String]? {
        switch how {
        case .new(let url):
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            func list(_ s: String?) -> [String] {
                (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let item = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
            var args = ["new", item("subject") ?? ""]
            for a in list(c.path) { args += ["to", a] }
            for a in list(item("cc")) { args += ["cc", a] }
            for a in list(item("bcc")) { args += ["bcc", a] }
            return args
        case .respond(_, let kind, let place):
            guard let place else { return nil }
            return [
                kind == .reply ? "reply" : kind == .replyAll ? "replyAll" : "forward", place.accountID, place.path,
                String(place.id),
            ]
        }
    }

    static let needsAccessibility =
        "Nothing was sent: Latchkey writes email in Mail's own window, which needs Accessibility. The Mac's owner can turn on Latchkey in System Settings → Privacy & Security → Accessibility."

    static let whileLocked =
        "Nothing was sent: the Mac is locked, and Mail can't open its message window until someone unlocks it. mail_queue can queue it to go out the next time the Mac is unlocked; ask the Owner whether waiting is fine. Reading, finding, and organising email still work."

    func unavailable() async -> String? {
        guard AXIsProcessTrusted() else { return Self.needsAccessibility }
        // With the lid closed or the display off Mail's window works, but while the session is
        // locked Mail opens no window Accessibility can use (checked live 2026-11-01).
        return SystemScreen().isLocked() ? Self.whileLocked : nil
    }

    /// An app-modal alert holds Mail's scripting until it's answered: "could not be moved to the
    /// mailbox … Invalid base64 string for MIME content" after a send with the lid closed
    /// (2026-11-01). One with a single button only tells something, so pressing it loses nothing;
    /// one with more is a choice, left for someone at the Mac. Mail isn't started for this.
    func alert() async -> MailAlert? {
        guard AXIsProcessTrusted(),
            let mail = NSRunningApplication.runningApplications(withBundleIdentifier: MailCapability.mailApp).first
        else { return nil }
        let app = AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 3)
        let windows = AX.windows(app)
        let dialog = windows.first { ["AXDialog", "AXSystemDialog"].contains(AX.string($0, kAXSubroleAttribute)) }
        // A sheet on a viewer or settings window is only named, never pressed (security review).
        let sheet = windows.lazy.filter { !AX.isCompose($0) }.compactMap { AX.sheet($0) }.first
        guard let alert = dialog ?? sheet else { return nil }
        var buttons: [AXUIElement] = []
        var otherControls = 0
        AX.walk(alert, depth: 6) { e in
            switch AX.string(e, kAXRoleAttribute) {
            case "AXButton": buttons.append(e)
            case "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox":
                otherControls += 1
            default: break
            }
        }
        let titles = buttons.compactMap { AX.string($0, kAXTitleAttribute) }
        let text = AX.texts(alert).joined(separator: " ")
        var closed = false
        // Pressed only when the alert's one control is its default button: it only informs.
        if dialog != nil, buttons.count == 1, otherControls == 0,
            let main = AX.value(alert, kAXDefaultButtonAttribute), CFGetTypeID(main) == AXUIElementGetTypeID(),
            CFEqual(main, buttons[0])
        {
            AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(300))
            closed = !AX.alive(alert)
        }
        return MailAlert(text: text, buttons: titles, closed: closed)
    }

    /// Seconds since the Owner last typed, clicked, or moved the pointer.
    static func idleSeconds() -> Double {
        let kinds: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel,
        ]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// Waits up to 30 s for a 1-second pause in the Owner's typing and pointer, so keys they type
    /// don't land in Mail while it is in front (FR-840); without one, nothing more is done
    /// (security review 2026-11-02).
    static func waitForPause() async throws {
        for _ in 0..<120 where idleSeconds() < 1 {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard idleSeconds() >= 1 else {
            throw ComposeFailure(
                message:
                    "the Mac's owner kept typing for 30 seconds, so Mail wasn't brought forward (it would have taken their keys)"
            )
        }
    }

    /// Runs `body` with Mail in front, then gives the front back to the app the Owner was using,
    /// unless they switched elsewhere meanwhile (FR-840).
    func inFront<T>(_ mail: NSRunningApplication, _ body: () async throws -> T) async throws -> T {
        try await Self.waitForPause()
        let front = NSWorkspace.shared.frontmostApplication
        let other = front?.processIdentifier == mail.processIdentifier ? nil : front
        lock.withLock { if previous == nil, let other { previous = other } }
        try await Self.bringForward(mail)
        defer {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == mail.processIdentifier {
                (other ?? lock.withLock { previous })?.activate()
            }
        }
        return try await body()
    }

    /// Brings `app` to the front and waits until it is. macOS may ignore a plain activate from
    /// an app that isn't in front (seen 2026-11-02: Send then went unpressed); opening the app
    /// through macOS always brings it forward.
    static func bringForward(_ app: NSRunningApplication) async throws {
        app.activate()
        for i in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            if i == 4, let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ComposeFailure(message: "Mail didn't come to the front for the moment it needs")
    }

    func open(_ how: ComposeOpening) async throws -> any ComposeWindow {
        let mail = try await Self.mailApp()
        let app = AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 3)
        // Made by Mail's scripting, Mail stays behind (FR-840); else Mail in front for the moment.
        if let args = Self.makeArguments(how) {
            let before = AX.windows(app)
            let id = try await scripts.run(Self.makeScript, args).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let w = await AX.waitForNew(app, before: before, compose: true) else {
                _ = try? await scripts.run(Self.messageScript, [id, "close"])
                throw ComposeFailure(message: "Mail didn't show the message's window.")
            }
            for _ in 0..<40 where AX.find(w, depth: 6, { AX.string($0, kAXRoleAttribute) == "AXWebArea" }) == nil {
                try await Task.sleep(for: .milliseconds(125))
            }
            AX.park(w)
            let isNew = if case .new = how { true } else { false }
            return AXComposeWindow(app: app, window: w, owner: self, scriptID: Int(id), isNew: isNew)
        }
        // The Owner's own Mail window, to be the one their keys go to again (security review).
        let ownersMain = AX.value(app, kAXMainWindowAttribute).flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        let w = try await inFront(mail) { try await openInFront(how, mail: mail, app: app) }
        AX.park(w)
        if let ownersMain, AX.alive(ownersMain), !CFEqual(ownersMain, w) { AX.makeMain(ownersMain) }
        return AXComposeWindow(app: app, window: w, owner: self)
    }

    /// Mail's window, with its message text area loaded (Mail builds it only while in front).
    private func openInFront(_ how: ComposeOpening, mail: NSRunningApplication, app: AXUIElement) async throws
        -> AXUIElement
    {
        let w = try await openWindow(how, mail: mail, app: app)
        for _ in 0..<40 where AX.find(w, depth: 6, { AX.string($0, kAXRoleAttribute) == "AXWebArea" }) == nil {
            try await Task.sleep(for: .milliseconds(125))
        }
        return w
    }

    private func openWindow(_ how: ComposeOpening, mail: NSRunningApplication, app: AXUIElement) async throws
        -> AXUIElement
    {
        let before = AX.windows(app)
        guard let mailURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MailCapability.mailApp) else {
            throw ComposeFailure(message: "Mail isn't on this Mac.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        switch how {
        case .new(let url):
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: mailURL, configuration: config)
            guard let w = await AX.waitForNew(app, before: before, compose: true) else {
                await closeLate(app, before: before)
                throw ComposeFailure(message: "Mail didn't open a new message window.")
            }
            return w
        case .respond(let messageID, let kind, _):
            let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard
                let encoded = id.addingPercentEncoding(
                    withAllowedCharacters: CharacterSet(
                        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._@$")),
                let url = URL(string: "message://%3c\(encoded)%3e")
            else { throw ComposeFailure(message: "The original's Message-ID can't be opened in Mail.") }
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: mailURL, configuration: config)
            guard let viewer = await AX.waitForNew(app, before: before, compose: false) else {
                throw ComposeFailure(message: "Mail didn't open the original message in a window of its own.")
            }
            defer { AX.close(viewer) }
            let (key, mods): (String, Int) =
                switch kind {
                case .reply: ("R", 0)
                case .replyAll: ("R", AX.shift)
                case .forward: ("F", AX.shift)
                }
            // Mail enables Reply once the message's window is in front and loaded.
            var command: AXUIElement?
            for _ in 0..<16 {
                mail.activate()
                AX.makeMain(viewer)
                try await Task.sleep(for: .milliseconds(250))
                if let item = AX.menuItem(app, key: key, modifiers: mods),
                    (AX.value(item, kAXEnabledAttribute) as? Bool) == true
                {
                    command = item
                    break
                }
            }
            guard let item = command else {
                throw ComposeFailure(message: "Mail's \(kind.rawValue) command isn't available for that message.")
            }
            let withViewer = AX.windows(app)
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard let w = await AX.waitForNew(app, before: withViewer, compose: true) else {
                await closeLate(app, before: withViewer)
                throw ComposeFailure(message: "Mail didn't open the \(kind == .forward ? "forward" : "reply") window.")
            }
            return w
        }
    }

    /// A compose window Mail opens after Latchkey stopped waiting is closed unsent, so none is
    /// left on the screen.
    private func closeLate(_ app: AXUIElement, before: [AXUIElement]) async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            for w in AX.windows(app) where AX.isCompose(w) && !before.contains(where: { CFEqual($0, w) }) {
                _ = await AXComposeWindow(app: app, window: w, owner: self).discard()
                return
            }
        }
    }

    func finish() async {
        let front = lock.withLock {
            defer { previous = nil }
            return previous
        }
        // Only when Mail is still in front: the Owner may have gone to another app meanwhile.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MailCapability.mailApp { front?.activate() }
    }

    static func mailApp() async throws -> NSRunningApplication {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: MailCapability.mailApp).first {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MailCapability.mailApp) else {
            throw ComposeFailure(message: "Mail isn't on this Mac.")
        }
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        try await Task.sleep(for: .seconds(2))
        return app
    }
}

/// One compose window of Mail's.
final class AXComposeWindow: ComposeWindow, @unchecked Sendable {
    let app: AXUIElement
    let window: AXUIElement
    let owner: AXMailWindows
    /// The outgoing message's id when Mail's scripting made it: then files, Send, and saving go
    /// through scripting too, with Mail behind (FR-840).
    let scriptID: Int?
    /// A new message (not a reply or forward), whose text scripting may rewrite freely.
    let isNew: Bool
    private var typed = false

    init(app: AXUIElement, window: AXUIElement, owner: AXMailWindows, scriptID: Int? = nil, isNew: Bool = false) {
        self.app = app
        self.window = window
        self.owner = owner
        self.scriptID = scriptID
        self.isNew = isNew
    }

    private var mail: NSRunningApplication? {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Whether Mail's focus is in `target` (it, or something inside it).
    private func focused(in target: AXUIElement) -> Bool {
        guard let f = AX.value(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else {
            // No focused element (seen after a scripted attach): Mail's focused window decides.
            guard let w = AX.value(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else {
                return false
            }
            return CFEqual(w, target)
        }
        var e: AXUIElement? = (f as! AXUIElement)
        // The window it is in, when that is what's asked.
        if let w = AX.value(f as! AXUIElement, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID(),
            CFEqual(w, target)
        {
            return true
        }
        for _ in 0..<20 {
            guard let current = e else { return false }
            if CFEqual(current, target) { return true }
            e = AX.value(current, kAXParentAttribute).flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
        }
        return false
    }

    /// Types `text` into `target` with keys sent to Mail alone, so Mail can stay behind (checked
    /// live 2026-11-02: "äö €" arrived exactly in a background window). False, with nothing more
    /// typed, as soon as Mail's focus isn't in this message's window (security review 2026-11-02).
    /// Mail reports a window behind as focused on its To field while keys reach the text, so the
    /// window is what is checked; MailCompose checks every field before anything goes out.
    private func typeToMail(_ text: String, into target: AXUIElement) async throws -> Bool {
        guard let mail else { return false }
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let source = CGEventSource(stateID: .privateState)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 {
                guard focused(in: window) else { return false }
                for down in [true, false] {
                    CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(
                        mail.processIdentifier)
                }
            }
            var units = Array(line.utf16)[...]
            while !units.isEmpty {
                guard focused(in: window) else { return false }
                let chunk = Array(units.prefix(16))
                units = units.dropFirst(chunk.count)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    e?.postToPid(mail.processIdentifier)
                }
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        return true
    }

    private func element(_ id: String) -> AXUIElement? {
        AX.find(window, depth: 4) { AX.string($0, "AXIdentifier") == id }
    }
    private var body: AXUIElement? { AX.find(window, depth: 6) { AX.string($0, kAXRoleAttribute) == "AXWebArea" } }

    func fields() async throws -> ComposeFields {
        guard AX.alive(window) else { throw ComposeFailure(message: "Mail's window closed.") }
        var f = ComposeFields()
        func tokens(_ id: String) -> [String] {
            guard let field = element(id) else { return [] }
            return AX.children(field).compactMap { AX.string($0, kAXValueAttribute) }.filter { !$0.isEmpty }
        }
        f.to = tokens("Mail.toField")
        f.cc = tokens("Mail.ccField")
        f.bcc = tokens("Mail.bccField")
        f.subject = element("Mail.subjectField").flatMap { AX.string($0, kAXValueAttribute) } ?? ""
        f.from = element("popup_from").flatMap { AX.string($0, kAXValueAttribute) } ?? ""
        if let body {
            AX.walk(body, depth: 12) { e in
                let role = AX.string(e, kAXRoleAttribute)
                if role == "AXStaticText", let text = AX.string(e, kAXValueAttribute) {
                    let level = (AX.value(e, "AXBlockQuoteLevel") as? NSNumber)?.intValue ?? 0
                    f.body.append((text, level))
                } else if role == "AXButton", let d = AX.string(e, kAXDescriptionAttribute), !d.isEmpty {
                    f.attachments.append(d)
                }
            }
        }
        return f
    }

    func chooseSender(_ address: String) async throws -> Bool {
        guard let popup = element("popup_from") else { return false }
        // Mail's own choice is often already the one asked for.
        if (AX.string(popup, kAXValueAttribute) ?? "").lowercased().hasSuffix(address.lowercased()) { return true }
        if let chosen = try await pickSender(popup, address) { return chosen }
        guard let mail else { return false }
        return try await owner.inFront(mail) {
            AX.makeMain(window)
            return try await pickSender(popup, address) ?? false
        }
    }

    /// nil when the From menu didn't open (Mail behind).
    private func pickSender(_ popup: AXUIElement, _ address: String) async throws -> Bool? {
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        try await Task.sleep(for: .milliseconds(400))
        guard let menu = AX.children(popup).first(where: { AX.string($0, kAXRoleAttribute) == "AXMenu" }) else {
            return nil
        }
        let wanted = address.lowercased()
        if let item = AX.children(menu).first(where: { item in
            let title = (AX.string(item, kAXTitleAttribute) ?? "").lowercased()
            return title.hasSuffix(wanted) || title.hasSuffix("<\(wanted)>")
        }) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            try await Task.sleep(for: .milliseconds(300))
            return true
        }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        return false
    }

    func addRecipients(_ addresses: [String], to field: RecipientField) async throws {
        let id = "Mail.\(field.rawValue)Field"
        if element(id) == nil, field == .bcc, let item = AX.menuItem(app, key: "B", modifiers: AX.option) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)  // View → Bcc Address Field
            try await Task.sleep(for: .milliseconds(400))
        }
        guard let target = element(id) else {
            throw ComposeFailure(message: "Mail's window has no \(field.rawValue.capitalized) field.")
        }
        let before = AX.children(target).count
        let text = addresses.joined(separator: ", ") + ", "
        // At the end of the field, so Mail's own recipients stay (MailCompose checks they did).
        if !insert(text, into: target, atEnd: true) || AX.children(target).count == before {
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AX.moveCursorToEnd(target)
            _ = try await typeToMail(text, into: target)
            try await Task.sleep(for: .milliseconds(300))
        }
        if AX.children(target).count == before {
            try await paste(into: target, ClipboardLoan.text(text), atEnd: true)
        }
        AXUIElementPerformAction(target, kAXConfirmAction as CFString)
    }

    /// Sets the selected text of the element (at its end, or where Mail put the cursor) through
    /// Accessibility, without the clipboard; false when Mail doesn't take it that way.
    private func insert(_ text: String, into target: AXUIElement, atEnd: Bool) -> Bool {
        AX.makeMain(window)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if atEnd { AX.moveCursorToEnd(target) }
        return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// The message text area, which Mail fills in a moment after the window opens.
    private func loadedBody() async throws -> AXUIElement {
        for _ in 0..<40 {
            if let body { return body }
            try await Task.sleep(for: .milliseconds(125))
        }
        throw ComposeFailure(message: "Mail's window has no message text area.")
    }

    /// The body's text, to see whether Accessibility put the text in.
    private func bodyText() -> String {
        guard let body else { return "" }
        var runs: [String] = []
        AX.walk(body, depth: 12) { e in
            if AX.string(e, kAXRoleAttribute) == "AXStaticText", let t = AX.string(e, kAXValueAttribute) {
                runs.append(t)
            }
        }
        return MailCompose.collapse(runs.joined(separator: "\n"))
    }

    func insertText(_ text: String) async throws {
        let body = try await loadedBody()
        let wanted = MailCompose.collapse(text)
        typed = true
        let before = bodyText()
        // Setting the text through Accessibility does nothing in a window behind (2026-11-02);
        // keys sent to Mail alone do.
        if try await typeToMail(text, into: body) {
            // Mail shows the change a moment later.
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(125))
                if bodyText() != before { return }  // MailCompose checks it is the text, unquoted
            }
        } else if bodyText() != before {
            // Focus moved mid-text: what went in is incomplete, so nothing goes out.
            throw ComposeFailure(message: "Mail's focus left the message while its text was typed")
        }
        guard bodyText() == before, !wanted.isEmpty else { return }
        try await paste(into: body, ClipboardLoan.text(text), atEnd: false)
    }

    func attachFiles(_ files: [URL]) async throws {
        let body = try await loadedBody()
        // By scripting only before any text is typed (it rewrites the text), and not into a
        // reply's or forward's quoted original, which it may rewrite too.
        if let scriptID, isNew, !typed {
            _ = try await owner.scripts.run(
                AXMailWindows.messageScript, [String(scriptID), "attach"] + files.map(\.path))
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(150))
                if try await fields().attachments.count >= files.count { return }
            }
        }
        try await paste(into: body, ClipboardLoan.files(files), atEnd: false)
    }

    /// Edit → Paste into the element, with Mail in front and this window its main one, the
    /// clipboard lent for just this paste (`ClipboardLoan`).
    private func paste(into target: AXUIElement, _ items: [[String: Data]], atEnd: Bool) async throws {
        guard let mail else { throw ComposeFailure(message: "Mail isn't running.") }
        try await owner.inFront(mail) { try await pasteInFront(into: target, items, atEnd: atEnd) }
    }

    private func pasteInFront(into target: AXUIElement, _ items: [[String: Data]], atEnd: Bool) async throws {
        let loan = ClipboardLoan(owner.pasteboard, items: items)
        defer { loan.giveBack() }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        var paste: AXUIElement?
        // Mail in front, this window its main one, the cursor in the target; Mail enables Paste
        // once all three hold (a moment after the window opened or another closed).
        for _ in 0..<12 {
            NSRunningApplication(processIdentifier: pid)?.activate()
            AX.makeMain(window)
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if atEnd { AX.moveCursorToEnd(target) }
            try await Task.sleep(for: .milliseconds(250))
            if let item = AX.menuItem(app, key: "V", modifiers: 0),
                (AX.value(item, kAXEnabledAttribute) as? Bool) == true
            {
                paste = item
                break
            }
        }
        guard let paste else {
            throw ComposeFailure(
                message: "Mail wouldn't paste into its window (someone may have switched to another app meanwhile).")
        }
        // Someone copied something meanwhile: Mail would paste theirs, so nothing is pasted.
        guard loan.intact else {
            throw ComposeFailure(message: "the clipboard changed while Latchkey was using it, so nothing was pasted")
        }
        AXUIElementPerformAction(paste, kAXPressAction as CFString)
        try await Task.sleep(for: .milliseconds(400))
    }

    func send() async throws {
        if let scriptID {
            // Mail's scripting sends what MailCompose checked, with Mail behind (FR-840).
            _ = try await owner.scripts.run(AXMailWindows.messageScript, [String(scriptID), "send"])
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                if !AX.alive(window) { return }
            }
            throw ComposeFailure(message: "Mail's window stayed open after Send", afterSend: true)
        }
        guard let button = element("send") else { throw ComposeFailure(message: "Mail's window has no Send button.") }
        guard let mail else { throw ComposeFailure(message: "Mail isn't running.") }
        // Mail ignores Send pressed while behind (2026-11-02); in front for the press only.
        let checked = try await fields()
        try await owner.inFront(mail) {
            AX.makeMain(window)
            // What MailCompose checked is still what goes out (security review 2026-11-02).
            guard try await fields() == checked else {
                throw ComposeFailure(message: "Mail's window changed just before Send")
            }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            try await Task.sleep(for: .milliseconds(150))
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if !AX.alive(window) { return }
            if let sheet = AX.sheet(window) {
                let text = AX.texts(sheet).joined(separator: " ")
                throw ComposeFailure(message: "Mail showed «\(text)» after Send", afterSend: true)
            }
        }
        throw ComposeFailure(message: "Mail's window stayed open after Send", afterSend: true)
    }

    func saveDraft() async throws {
        if let scriptID {
            _ = try await owner.scripts.run(AXMailWindows.messageScript, [String(scriptID), "save"])
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                if !AX.alive(window) { return }
            }
            throw ComposeFailure(message: "Mail's window stayed open after saving the draft.")
        }
        guard let mail else { throw ComposeFailure(message: "Mail isn't running.") }
        try await owner.inFront(mail) {
            AX.makeMain(window)
            try await Task.sleep(for: .milliseconds(200))
            guard let save = AX.menuItem(app, key: "S", modifiers: 0) else {
                throw ComposeFailure(message: "Mail's Save command isn't available.")
            }
            AXUIElementPerformAction(save, kAXPressAction as CFString)
            try await Task.sleep(for: .milliseconds(500))
        }
        try await Task.sleep(for: .milliseconds(500))
        AX.close(window)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            if !AX.alive(window) { return }
            if let sheet = AX.sheet(window), let keep = AX.button(sheet, id: "action-button-1") {
                AXUIElementPerformAction(keep, kAXPressAction as CFString)  // Save
            }
        }
        throw ComposeFailure(message: "Mail's window stayed open after saving the draft.")
    }

    func discard() async -> Bool {
        guard AX.alive(window) else { return true }
        // Mail's alert first, by its Cancel button only: another button could be "Send Anyway".
        if let sheet = AX.sheet(window), let cancel = AX.value(sheet, kAXCancelButtonAttribute),
            CFGetTypeID(cancel) == AXUIElementGetTypeID()
        {
            AXUIElementPerformAction(cancel as! AXUIElement, kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(300))
        }
        AX.close(window)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if !AX.alive(window) { return true }
            guard let sheet = AX.sheet(window) else { continue }
            if let dont = AX.button(sheet, id: "action-button-3") {
                AXUIElementPerformAction(dont, kAXPressAction as CFString)  // Don't Save
            } else if body == nil,
                AX.children(sheet).filter({ AX.string($0, kAXRoleAttribute) == "AXButton" }).count == 2,
                let ok = AX.button(sheet, id: "action-button-1")
            {
                // "Unable to Load Window … Are you sure you want to close it?" (OK, Cancel): a
                // window closed before its text area loaded, seen with the lid closed. Only for a
                // window with no text area, which holds no text to send or lose (security review).
                AXUIElementPerformAction(ok, kAXPressAction as CFString)
            }
        }
        return !AX.alive(window)
    }
}

/// Small Accessibility helpers.
enum AX {
    static let shift = 1  // kAXMenuItemModifierShift
    static let option = 2  // kAXMenuItemModifierOption

    static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? { value(e, attribute) as? String }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func alive(_ window: AXUIElement) -> Bool { string(window, kAXRoleAttribute) != nil }

    static func find(_ e: AXUIElement, depth: Int, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(e) { return e }
        guard depth > 0 else { return nil }
        for k in children(e) { if let f = find(k, depth: depth - 1, match) { return f } }
        return nil
    }

    static func walk(_ e: AXUIElement, depth: Int, _ body: (AXUIElement) -> Void) {
        body(e)
        guard depth > 0 else { return }
        for k in children(e) { walk(k, depth: depth - 1, body) }
    }

    static func isCompose(_ w: AXUIElement) -> Bool {
        children(w).contains { string($0, "AXIdentifier") == "Mail.subjectField" }
    }

    /// A window that wasn't there before, of the kind asked for, within 8 seconds.
    static func waitForNew(_ app: AXUIElement, before: [AXUIElement], compose: Bool) async -> AXUIElement? {
        for _ in 0..<32 {
            try? await Task.sleep(for: .milliseconds(250))
            if let w = windows(app).first(where: { w in
                !before.contains { CFEqual($0, w) } && isCompose(w) == compose
            }) {
                return w
            }
        }
        return nil
    }

    /// Puts the cursor after the element's last character.
    static func moveCursorToEnd(_ e: AXUIElement) {
        let count =
            (value(e, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            ?? (string(e, kAXValueAttribute) as NSString?)?.length ?? 0
        var range = CFRange(location: count, length: 0)
        if let v = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, v)
        }
    }

    /// Moves a window off the screen (macOS keeps a strip of it on screen at the corner).
    static func park(_ w: AXUIElement) {
        var p = CGPoint(x: -10000, y: 10000)
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    static func makeMain(_ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func close(_ w: AXUIElement) {
        if let b = children(w).first(where: { string($0, kAXSubroleAttribute) == "AXCloseButton" }) {
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        }
    }

    static func sheet(_ w: AXUIElement) -> AXUIElement? {
        children(w).first { string($0, kAXRoleAttribute) == "AXSheet" }
    }

    static func button(_ sheet: AXUIElement, id: String) -> AXUIElement? {
        children(sheet).first { string($0, "AXIdentifier") == id }
    }

    static func texts(_ e: AXUIElement) -> [String] {
        var out: [String] = []
        walk(e, depth: 3) { x in
            if string(x, kAXRoleAttribute) == "AXStaticText", let v = string(x, kAXValueAttribute) { out.append(v) }
        }
        return out
    }

    /// The menu bar item with this key equivalent (⌘ plus `modifiers`), in any menu.
    static func menuItem(_ app: AXUIElement, key: String, modifiers: Int) -> AXUIElement? {
        guard let barValue = value(app, kAXMenuBarAttribute), CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let bar = barValue as! AXUIElement
        return find(bar, depth: 4) { e in
            string(e, kAXRoleAttribute) == "AXMenuItem"
                && string(e, kAXMenuItemCmdCharAttribute)?.uppercased() == key
                && (value(e, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == modifiers
        }
    }
}
