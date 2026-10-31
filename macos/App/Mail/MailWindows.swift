import AppKit
import ApplicationServices

/// Mail's compose windows through Accessibility (plan D6; research "Compose window"). Fields are
/// found by Mail's own identifiers (`Mail.toField`, `popup_from`, `send`), menu items by their
/// key equivalents (⌘V, ⌘R, ⇧⌘R, ⇧⌘F, ⌘S), so a different language doesn't matter; text and
/// files arrive by Edit → Paste, and the Owner's clipboard is put back after.
final class AXMailWindows: ComposeWindows, @unchecked Sendable {
    private let screen: any ScreenStateSource
    private let lock = NSLock()
    private var previous: NSRunningApplication?
    private var savedClipboard: [NSPasteboardItem]?

    init(screen: any ScreenStateSource = SystemScreen()) { self.screen = screen }

    static let needsAccessibility =
        "Nothing was sent: Latchkey writes email in Mail's own window, which needs Accessibility. The Mac's owner can turn on Latchkey in System Settings → Privacy & Security → Accessibility."

    func unavailable() async -> String? {
        guard AXIsProcessTrusted() else { return Self.needsAccessibility }
        if let problem = await ScreenCheck.problem(screen) {
            return
                "Nothing was sent: Latchkey can't write email while the Mac's screen is off or locked, because Mail writes it in a window on the screen. (\(problem))"
        }
        return nil
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
                throw ComposeFailure(message: "Mail didn't open the \(kind == .forward ? "forward" : "reply") window.")
            }
            return AXComposeWindow(app: app, window: w, owner: self)
        }
    }

    func finish() async {
        let (front, clip) = lock.withLock {
            defer {
                previous = nil
                savedClipboard = nil
            }
            return (previous, savedClipboard)
        }
        if let clip {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(clip)
        }
        front?.activate()
    }

    /// Puts things on the clipboard for one paste, keeping the Owner's clipboard to put back.
    func setClipboard(_ write: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        lock.withLock {
            if savedClipboard == nil {
                savedClipboard = (pb.pasteboardItems ?? []).map { item in
                    let copy = NSPasteboardItem()
                    for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
                    return copy
                }
            }
        }
        pb.clearContents()
        write(pb)
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
        try await paste(into: target) { $0.setString(addresses.joined(separator: ", ") + ", ", forType: .string) }
        AXUIElementPerformAction(target, kAXConfirmAction as CFString)
    }

    /// The message text area, which Mail fills in a moment after the window opens.
    private func loadedBody() async throws -> AXUIElement {
        for _ in 0..<40 {
            if let body { return body }
            try await Task.sleep(for: .milliseconds(125))
        }
        throw ComposeFailure(message: "Mail's window has no message text area.")
    }

    func pasteText(_ text: String) async throws {
        let body = try await loadedBody()
        try await paste(into: body) { $0.setString(text, forType: .string) }
    }

    func pasteFiles(_ files: [URL]) async throws {
        let body = try await loadedBody()
        try await paste(into: body) { $0.writeObjects(files.map { $0 as NSURL }) }
    }

    /// Edit → Paste into the element, with Mail in front and this window its main one.
    private func paste(into target: AXUIElement, _ write: (NSPasteboard) -> Void) async throws {
        owner.setClipboard(write)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        var paste: AXUIElement?
        // Mail in front, this window its main one, the cursor in the target; Mail enables Paste
        // once all three hold (a moment after the window opened or another closed).
        for _ in 0..<12 {
            NSRunningApplication(processIdentifier: pid)?.activate()
            AX.makeMain(window)
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(for: .milliseconds(250))
            if let item = AX.menuItem(app, key: "V", modifiers: 0), (AX.value(item, kAXEnabledAttribute) as? Bool) == true {
                paste = item
                break
            }
        }
        guard let paste else {
            throw ComposeFailure(
                message: "Mail wouldn't paste into its window (someone may have switched to another app meanwhile).")
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
                throw ComposeFailure(message: "Mail didn't send it: «\(text)»")
            }
        }
        throw ComposeFailure(message: "Mail's window stayed open after Send.")
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

    func discard() async {
        guard AX.alive(window) else { return }
        if let sheet = AX.sheet(window),
            let other = AX.children(sheet).last(where: { AX.string($0, kAXRoleAttribute) == "AXButton" })
        {
            AXUIElementPerformAction(other, kAXPressAction as CFString)  // dismiss Mail's alert first
            try? await Task.sleep(for: .milliseconds(300))
        }
        AX.close(window)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if !AX.alive(window) { return }
            if let sheet = AX.sheet(window), let dont = AX.button(sheet, id: "action-button-3") {
                AXUIElementPerformAction(dont, kAXPressAction as CFString)  // Don't Save
            }
        }
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
