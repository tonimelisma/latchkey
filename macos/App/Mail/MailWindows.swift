import AppKit
import ApplicationServices

/// Mail's compose windows through Accessibility (plan D6; research "Compose window"). Fields are
/// found by Mail's own identifiers (`Mail.toField`, `popup_from`, `send`), menu items by their
/// key equivalents (⌘V, ⌘R, ⇧⌘R, ⇧⌘F, ⌘S), so a different language doesn't matter. Text and
/// recipients go in through Accessibility (the selected text set at the cursor); only files, and
/// text Mail didn't take that way, go by Edit → Paste with the clipboard lent (`ClipboardLoan`).
/// All of it works with the display off or the lid closed, but not while locked (checked live 2026-11-01:
/// sent with a file and a draft saved with the lid closed and unlocked; nothing opens while locked).
final class AXMailWindows: ComposeWindows, @unchecked Sendable {
    let pasteboard: any Pasteboard
    private let lock = NSLock()
    private var previous: NSRunningApplication?

    init(pasteboard: any Pasteboard = GeneralPasteboard()) {
        self.pasteboard = pasteboard
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
        let alerts = AX.windows(app).compactMap { w -> AXUIElement? in
            if ["AXDialog", "AXSystemDialog"].contains(AX.string(w, kAXSubroleAttribute)) { return w }
            return AX.isCompose(w) ? nil : AX.sheet(w)
        }
        guard let alert = alerts.first else { return nil }
        let buttons = AX.children(alert).filter { AX.string($0, kAXRoleAttribute) == "AXButton" }
        let titles = buttons.compactMap { AX.string($0, kAXTitleAttribute) }
        let text = AX.texts(alert).joined(separator: " ")
        var closed = false
        if buttons.count == 1 {
            AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(300))
            closed = !AX.alive(alert)
        }
        return MailAlert(text: text, buttons: titles, closed: closed)
    }

    func open(_ how: ComposeOpening) async throws -> any ComposeWindow {
        let mail = try await Self.mailApp()
        lock.withLock {
            let front = NSWorkspace.shared.frontmostApplication
            if previous == nil, front?.processIdentifier != mail.processIdentifier { previous = front }
        }
        let app = AXUIElementCreateApplication(mail.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 3)
        mail.activate()
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
            return AXComposeWindow(app: app, window: w, owner: self)
        case .respond(let messageID, let kind):
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
            return AXComposeWindow(app: app, window: w, owner: self)
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
        front?.activate()
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

    init(app: AXUIElement, window: AXUIElement, owner: AXMailWindows) {
        self.app = app
        self.window = window
        self.owner = owner
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
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        try await Task.sleep(for: .milliseconds(400))
        guard let menu = AX.children(popup).first(where: { AX.string($0, kAXRoleAttribute) == "AXMenu" }) else {
            return false
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
        let before = bodyText()
        if insert(text, into: body, atEnd: false) {
            // Mail shows the change a moment later.
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(125))
                let now = bodyText()
                if now != before { return }  // MailCompose checks it is the text, unquoted
            }
        }
        guard bodyText() == before, !wanted.isEmpty else { return }
        try await paste(into: body, ClipboardLoan.text(text), atEnd: false)
    }

    func attachFiles(_ files: [URL]) async throws {
        let body = try await loadedBody()
        try await paste(into: body, ClipboardLoan.files(files), atEnd: false)
    }

    /// Edit → Paste into the element, with Mail in front and this window its main one, the
    /// clipboard lent for just this paste (`ClipboardLoan`).
    private func paste(into target: AXUIElement, _ items: [[String: Data]], atEnd: Bool) async throws {
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
        guard let button = element("send") else { throw ComposeFailure(message: "Mail's window has no Send button.") }
        AX.makeMain(window)
        AXUIElementPerformAction(button, kAXPressAction as CFString)
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
        AX.makeMain(window)
        try await Task.sleep(for: .milliseconds(200))
        guard let save = AX.menuItem(app, key: "S", modifiers: 0) else {
            throw ComposeFailure(message: "Mail's Save command isn't available.")
        }
        AXUIElementPerformAction(save, kAXPressAction as CFString)
        try await Task.sleep(for: .seconds(1))
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
