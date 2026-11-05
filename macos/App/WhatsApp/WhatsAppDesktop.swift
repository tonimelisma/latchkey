import AppKit
import ApplicationServices

/// The chat Latchkey acts on in WhatsApp for Mac, with what makes opening it certain (security
/// review 2026-11-05): a person by their number (WhatsApp's own link opens exactly that chat), the
/// Owner's own chat by the Owner's number, anything else only by a name no other chat has.
struct WhatsAppDesktopTarget: Equatable, Sendable {
    var chat: WhatsAppChat
    /// The person's phone number (the Owner's own for their own chat); nil for groups and unknown ones.
    var number: String?
    /// The Owner's own chat ("Message yourself", shown as You), known by its id.
    var isSelf = false
    /// No other visible chat in WhatsApp for Mac's database has this name.
    var nameIsUnique = false
}

/// What Latchkey asks WhatsApp for Mac to send (spec 012 FR-1245, FR-1246).
struct WhatsAppDesktopSend: Equatable, Sendable {
    var target: WhatsAppDesktopTarget
    var text: String
    var files: [URL]
    var replyTo: WhatsAppMessage?

    var chat: WhatsAppChat { target.chat }
    var number: String? { target.number }
}

/// How an action through WhatsApp for Mac ended.
enum WhatsAppDesktopResult: Equatable, Sendable {
    /// Done, and how it was confirmed ("" when there is nothing to add).
    case done(String)
    /// Nothing happened, and why.
    case notDone(String)
    /// It may have happened; WhatsApp didn't confirm it.
    case unsure(String)
}

/// WhatsApp for Mac's window, when the Owner's Safari tab can't be used (plan D3b).
protocol WhatsAppDesktopAPI: Sendable {
    /// Why WhatsApp for Mac's window can't be used now, in words; nil when it can.
    func unusable() -> String?
    func send(_ request: WhatsAppDesktopSend) async -> WhatsAppDesktopResult
    func react(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, emoji: String) async
        -> WhatsAppDesktopResult
    func delete(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, everyone: Bool) async
        -> WhatsAppDesktopResult
}

/// WhatsApp for Mac driven through Accessibility (plan D3b, research "WhatsApp for Mac's window",
/// 2026-11-05). WhatsApp for Mac (a Mac Catalyst app) shows its whole window to Accessibility while
/// the Mac is unlocked: chats, messages, the message menu (Reply, React, Delete), the selection bar,
/// and the delete dialog all answer AXPress and AXShowMenu with WhatsApp behind other windows. With
/// the Mac locked it shows nothing but its menu bar, so nothing works then (checked 2026-11-05).
/// Every action is bound to the message by its id: the bubble must be the only one that looks like
/// it, and the database must show that very message changed afterwards.
struct WhatsAppDesktop: WhatsAppDesktopAPI {
    static let bundleID = "net.whatsapp.WhatsApp"
    var store: @Sendable () -> WhatsAppStore?
    var locked: @Sendable () -> Bool = { SystemScreen().isLocked() }

    static let lockedReason =
        "the Mac is locked, and macOS shows WhatsApp for Mac's window to other apps only while it is unlocked"

    func unusable() -> String? {
        guard let app = Self.app() else { return "WhatsApp for Mac isn't running on the Mac" }
        if locked() { return Self.lockedReason }
        guard AXIsProcessTrusted() else {
            return
                "Latchkey isn't allowed to use Accessibility (System Settings → Privacy & Security → Accessibility)"
        }
        let w = WAWindow(pid: app.processIdentifier)
        guard w.messagePane() != nil || w.chatList() != nil else {
            return "WhatsApp for Mac has no window open (it may be closed or minimized)"
        }
        return nil
    }

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Waits up to 10 s for the database to show `done`.
    private func confirm(_ done: (WhatsAppStore) -> Bool) async -> Bool {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if let db = store(), done(db) { return true }
        }
        return false
    }

    // MARK: delete (checked 2026-11-05: seven messages deleted for me, in the background)

    func delete(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, everyone: Bool) async
        -> WhatsAppDesktopResult
    {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        if let why = await w.open(target) { return .notDone(why) }
        let bubble: AXUIElement
        switch await w.find(message) {
        case .failure(let p): return .notDone(p.message)
        case .success(let b): bubble = b
        }
        guard await w.menu(on: bubble, choose: "Delete") else {
            return .notDone("WhatsApp for Mac's message menu has no Delete")
        }
        // The chat is now in selection mode with this message selected; its Delete button asks how.
        guard await w.poll(3, { w.element(role: "AXStaticText", labelHasPrefix: "1 Selected") }) != nil else {
            await w.leaveSelection()
            return .notDone("WhatsApp for Mac didn't select the message")
        }
        guard let button = w.element(role: "AXButton", label: "Delete"), w.press(button) else {
            await w.leaveSelection()
            return .notDone("WhatsApp for Mac shows no Delete button")
        }
        let want = everyone ? "for everyone" : "for me"
        guard
            let choice = await w.poll(
                3, { w.element(role: "AXButton") { $0.hasPrefix("Delete") && $0.hasSuffix(want) } })
        else {
            w.closeMenus()
            await w.leaveSelection()
            return everyone
                ? .notDone("WhatsApp no longer offers deleting it for everyone (it may be too old)")
                : .notDone("WhatsApp for Mac didn't offer Delete for me")
        }
        guard w.press(choice) else { return .notDone("WhatsApp for Mac didn't take the press") }
        // That very message (by its id) gone (for me), or marked deleted (for everyone).
        let gone = await confirm { db in
            let now = try? db.message(chat: target.chat.id, key: message.key)
            return everyone ? (now == nil || now?.kind == "deleted") : now == nil
        }
        return gone ? .done("confirmed in its database") : .unsure("its database doesn't show that message deleted")
    }

    // MARK: react

    func react(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, emoji: String) async
        -> WhatsAppDesktopResult
    {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        let before = store()?.stamp(chat: target.chat.id, key: message.key)
        if let why = await w.open(target) { return .notDone(why) }
        let bubble: AXUIElement
        switch await w.find(message) {
        case .failure(let p): return .notDone(p.message)
        case .success(let b): bubble = b
        }
        guard await w.menu(on: bubble, choose: "React") else {
            return .notDone("WhatsApp for Mac's message menu has no React")
        }
        let picked = await w.pickReaction(emoji)
        guard case .done = picked else { return picked }
        // That very message (by its id) changed in the database.
        let changed = await confirm { db in
            let now = db.stamp(chat: target.chat.id, key: message.key)
            return now != nil && now != before
        }
        return changed ? .done("confirmed in its database") : .unsure("its database doesn't show that message changed")
    }

    // MARK: send

    func send(_ request: WhatsAppDesktopSend) async -> WhatsAppDesktopResult {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        let started = Date()
        if let why = await w.open(request.target) { return .notDone(why) }
        if let quoted = request.replyTo {
            let bubble: AXUIElement
            switch await w.find(quoted) {
            case .failure(let p): return .notDone(p.message)
            case .success(let b): bubble = b
            }
            guard await w.menu(on: bubble, choose: "Reply") else {
                return .notDone("WhatsApp for Mac's message menu has no Reply")
            }
        }
        let outcome = await w.compose(text: request.text, files: request.files)
        if case .notDone = outcome { return outcome }
        // A new message of the Owner's in that chat (by its id), with the text or a file.
        let wanted = request.files.isEmpty ? 1 : request.files.count
        let text = WhatsAppStore.clean(request.text) ?? ""
        let sent = await confirm { db in
            guard let recent = try? db.messages(chat: request.chat.id, before: nil, limit: wanted + 5) else {
                return false
            }
            let mine = recent.filter { $0.fromMe && $0.date >= started.addingTimeInterval(-5) }
            let withText = text.isEmpty || mine.contains { $0.text == text }
            return mine.count >= wanted && withText
        }
        return sent ? .done("confirmed in its database") : .unsure("its database doesn't show the message yet")
    }
}

/// WhatsApp for Mac's window through Accessibility. Its labels start with an invisible direction
/// mark (U+200E), which every comparison here removes.
struct WAWindow: @unchecked Sendable {
    let pid: pid_t
    let app: AXUIElement

    init(pid: pid_t) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
    }

    struct Item {
        var element: AXUIElement
        var role: String
        var label: String
        var value: String
    }

    static func clean(_ s: String?) -> String { WhatsAppStore.clean(s) ?? "" }

    /// Every element of the window (and open menus), once. While the Mac is locked WhatsApp lists
    /// itself as its own child; that loop is cut.
    func items(in root: AXUIElement? = nil, limit: Int = 6000) -> [Item] {
        var out: [Item] = []
        var queue: [(AXUIElement, Int)] = []
        var windows: AnyObject?
        if let root {
            queue = [(root, 0)]
        } else if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement]
        {
            queue = list.map { ($0, 0) }
        }
        var i = 0
        while i < queue.count, out.count < limit {
            let (e, depth) = queue[i]
            i += 1
            let role = WAWindow.string(e, kAXRoleAttribute) ?? ""
            if role == "AXApplication" { continue }
            let description = Self.clean(WAWindow.string(e, kAXDescriptionAttribute))
            let label = description.isEmpty ? Self.clean(WAWindow.string(e, kAXTitleAttribute)) : description
            out.append(
                Item(element: e, role: role, label: label, value: Self.clean(WAWindow.string(e, kAXValueAttribute))))
            guard depth < 40 else { continue }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                queue += list.map { ($0, depth + 1) }
            }
        }
        return out
    }

    func element(role: String, label: String) -> AXUIElement? {
        items().first { $0.role == role && $0.label == label }?.element
    }

    func element(role: String, labelHasPrefix prefix: String) -> AXUIElement? {
        items().first { $0.role == role && $0.label.hasPrefix(prefix) }?.element
    }

    func element(role: String, where test: (String) -> Bool) -> AXUIElement? {
        items().first { $0.role == role && test($0.label) }?.element
    }

    func chatList() -> AXUIElement? { element(role: "AXGroup", label: "List of chats") }

    /// The open chat's messages, labelled "Messages in chat with <name>".
    func messagePane() -> Item? {
        items().first { $0.role == "AXGroup" && $0.label.hasPrefix("Messages in chat with") }
    }

    @discardableResult
    func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }

    func perform(_ e: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(e, action as CFString) == .success
    }

    /// Looks again every 100 ms for up to `seconds`.
    func poll<T>(_ seconds: Double = 3, _ find: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let found = find() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < end
        return nil
    }

    /// Opens the target's chat without bringing WhatsApp forward, and only when it is certainly that
    /// chat (security review 2026-11-05): a person, or the Owner's own chat, by WhatsApp's own link
    /// for their number; a group or a person without a known number by their row in the chat list,
    /// only when no other chat has that name. Nil when it is open; otherwise why not.
    func open(_ target: WhatsAppDesktopTarget) async -> String? {
        let name = target.isSelf ? "You" : target.chat.name
        guard target.nameIsUnique else {
            return
                "another chat in WhatsApp for Mac has the same name, \("«\(target.chat.name)»"), so its window can't tell them apart"
        }
        if let number = target.number, !target.chat.isGroup {
            guard let url = URL(string: "whatsapp://send?phone=\(number)") else { return "that number isn't usable" }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.open(url, configuration: config)
            if await poll(5, { isOpen(name) ? true : nil }) != nil { return nil }
            return "WhatsApp for Mac didn't open the chat with \("«\(target.chat.name)»")"
        }
        if target.isSelf { return "the Owner's own number isn't known to WhatsApp for Mac" }
        if isOpen(name) { return nil }
        guard let row = await uniqueRow(name) else {
            return "WhatsApp for Mac's chat list doesn't show exactly one chat named \("«\(name)»")"
        }
        press(row)
        if await poll(3, { isOpen(name) ? true : nil }) != nil { return nil }
        return "WhatsApp for Mac didn't open \("«\(name)»")"
    }

    func isOpen(_ name: String) -> Bool {
        guard let pane = messagePane() else { return false }
        return Self.clean(String(pane.label.dropFirst("Messages in chat with".count))) == name
    }

    /// A chat row's name: its label up to the first comma ("Family, 3 unread messages").
    static func rowName(_ label: String) -> String { label.components(separatedBy: ",").first.map(clean) ?? "" }

    /// The chat list's one row named `name`, looking through the whole list a page at a time; nil
    /// when there is none or more than one. The list goes back to the top afterwards.
    func uniqueRow(_ name: String) async -> AXUIElement? {
        guard let list = chatList() else { return nil }
        var found: [AXUIElement] = []
        var lastPage: [String] = []
        for _ in 0..<40 {
            let rows = items().filter { $0.role == "AXButton" && $0.label != "Archived" && !$0.label.isEmpty }
            for row in rows
            where Self.rowName(row.label) == name && !found.contains(where: { CFEqual($0, row.element) }) {
                found.append(row.element)
            }
            let page = rows.map(\.label)
            if page == lastPage { break }
            lastPage = page
            guard perform(list, "AXScrollDownByPage") else { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        for _ in 0..<40 {
            guard perform(list, "AXScrollUpByPage") else { break }
            let page = items().filter { $0.role == "AXButton" }.map(\.label)
            if page == lastPage { break }
            lastPage = page
        }
        guard found.count == 1 else { return nil }
        return await poll(2, { items().first { $0.role == "AXButton" && Self.rowName($0.label) == name }?.element })
            ?? found.first
    }

    struct Refusal: Error { var message: String }

    /// Whether a bubble's label is this message's: the same side ("Your …" only for the Owner's own),
    /// its words or file name, and its date and time ("November 4, at 22:43"; today's carry the time
    /// alone). Security review 2026-11-05: date and time both, never words alone.
    static func matches(_ label: String, _ m: WhatsAppMessage, now: Date = Date()) -> Bool {
        let words = clean(m.text.isEmpty ? (m.fileName ?? "") : m.text)
        guard !words.isEmpty, label.hasPrefix("Your ") == m.fromMe, label.contains(words) else { return false }
        let english = Locale(identifier: "en_US_POSIX")
        let time = m.date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: .current, calendar: .current))
        let day = m.date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(month: .wide) \(day: .defaultDigits)", locale: english, timeZone: .current,
                calendar: .current))
        let year = m.date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)", locale: english, timeZone: .current, calendar: .current))
        if label.contains("\(day), at \(time)") || label.contains("\(day), \(year), at \(time)") { return true }
        // Today's messages: the time alone, with no other day named.
        guard Calendar.current.isDate(m.date, inSameDayAs: now), label.contains(time) else { return false }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = english
        let months = gregorian.monthSymbols
        return !months.contains { label.contains("\($0) ") } || label.contains("Today")
    }

    /// The message's bubble in the open chat, scrolling up for older ones. Refused when the message
    /// has no words or file name, or when more than one bubble matches.
    func find(_ m: WhatsAppMessage) async -> Result<AXUIElement, Refusal> {
        guard !(m.text.isEmpty && (m.fileName ?? "").isEmpty) else {
            return .failure(
                Refusal(message: "that message has no words or file name WhatsApp for Mac's window can be matched on"))
        }
        for _ in 0..<30 {
            // Only the open chat's messages: never the chat list or anything else in the window.
            guard let pane = messagePane() else { break }
            let hits = items(in: pane.element).filter { $0.role == "AXStaticText" && Self.matches($0.label, m) }
            if hits.count > 1 {
                return .failure(
                    Refusal(message: "more than one message in WhatsApp for Mac's window looks like that one"))
            }
            if let hit = hits.first {
                _ = perform(hit.element, "AXScrollToVisible")
                try? await Task.sleep(for: .milliseconds(200))
                return .success(hit.element)
            }
            guard perform(pane.element, "AXScrollUpByPage") else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .failure(Refusal(message: "WhatsApp for Mac's window doesn't show that message"))
    }

    /// Opens an element's menu (AXShowMenu) and chooses an item by its title; closes it otherwise.
    func menu(on e: AXUIElement, choose title: String) async -> Bool {
        guard perform(e, "AXShowMenu") else { return false }
        let item = await poll(2) {
            menuItems().first { Self.clean($0.label) == title }?.element
        }
        guard let item else {
            closeMenus()
            return false
        }
        return press(item)
    }

    /// The items of open menus (not the menu bar's).
    func menuItems() -> [Item] {
        var out: [Item] = []
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success else {
            return []
        }
        var queue = ((children as? [AXUIElement]) ?? []).map { ($0, 0) }
        var i = 0
        while i < queue.count, i < 4000 {
            let (e, depth) = queue[i]
            i += 1
            let role = WAWindow.string(e, kAXRoleAttribute) ?? ""
            if role == "AXMenuBar" || (role == "AXApplication" && depth > 0) { continue }
            if role == "AXMenuItem" {
                out.append(
                    Item(element: e, role: role, label: Self.clean(WAWindow.string(e, kAXTitleAttribute)), value: ""))
            }
            guard depth < 12 else { continue }
            var c: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success,
                let list = c as? [AXUIElement]
            {
                queue += list.map { ($0, depth + 1) }
            }
        }
        return out
    }

    func closeMenus() {
        for item in menuItems() {
            if let parent = WAWindow.parent(item.element) { _ = perform(parent, "AXCancel") }
        }
        key(53)
    }

    /// A key (a virtual key code) sent to WhatsApp alone.
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        var p: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &p) == .success, let p,
            CFGetTypeID(p) == AXUIElementGetTypeID()
        else { return nil }
        return (p as! AXUIElement)
    }

    /// Leaves the selection mode Delete opened, without deleting.
    func leaveSelection() async {
        if let cancel = element(role: "AXButton", label: "Cancel") { press(cancel) }
    }

    /// After the message menu's React: the emoji, from the quick row or WhatsApp's own picker.
    func pickReaction(_ emoji: String) async -> WhatsAppDesktopResult {
        let target = emoji.isEmpty ? nil : emoji
        guard
            let button = await poll(
                3,
                {
                    items().first { item in
                        item.role == "AXButton"
                            && (target.map { t in item.label == t || item.label.hasPrefix(t) } ?? false)
                    }?.element
                })
        else {
            closeMenus()
            return .notDone(
                target == nil
                    ? "WhatsApp for Mac doesn't offer taking a reaction off this way"
                    : "WhatsApp for Mac's reactions don't offer \(emoji)")
        }
        return press(button) ? .done("") : .notDone("WhatsApp for Mac didn't take the press")
    }

    /// Puts the text (and files) in the message box and sends it.
    func compose(text: String, files: [URL]) async -> WhatsAppDesktopResult {
        guard let box = await poll(2, { element(role: "AXTextArea", label: "Compose message") }) else {
            return .notDone("WhatsApp for Mac shows no message box for that chat")
        }
        // 1. In the background: text put in as if typed (AXSelectedText goes through the text view's
        // own insertion, unlike AXValue, which WhatsApp doesn't take).
        if files.isEmpty, Self.string(box, kAXValueAttribute).map(Self.clean)?.isEmpty ?? true {
            _ = AXUIElementSetAttributeValue(box, kAXSelectedTextAttribute as CFString, text as CFString)
            if let send = await poll(1.5, { element(role: "AXButton", label: "Send") }) {
                return press(send) ? .done("") : .notDone("WhatsApp for Mac didn't take the press on Send")
            }
            _ = AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, "" as CFString)
        }
        // 2. WhatsApp comes forward for a moment: only then do Paste and keys reach it. What the
        // Owner had on the clipboard is put back, and the app they were in comes back to the front.
        return await briefly { await pasteAndSend(box: box, text: text, files: files) }
    }

    /// Brings WhatsApp forward, runs `body`, then brings back the app that was in front.
    func briefly(_ body: () async -> WhatsAppDesktopResult) async -> WhatsAppDesktopResult {
        guard let whatsapp = NSRunningApplication(processIdentifier: pid) else {
            return .notDone("WhatsApp for Mac isn't running")
        }
        let previous = NSWorkspace.shared.frontmostApplication
        whatsapp.activate()
        guard await poll(2, { NSWorkspace.shared.frontmostApplication == whatsapp ? true : nil }) != nil else {
            return .notDone("WhatsApp for Mac didn't come to the front")
        }
        let result = await body()
        if let previous, previous != whatsapp { previous.activate() }
        return result
    }

    /// With WhatsApp in front: pastes the files (each opens WhatsApp's preview, sent with Return),
    /// then the text, and sends it.
    private func pasteAndSend(box: AXUIElement, text: String, files: [URL]) async -> WhatsAppDesktopResult {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        _ = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for file in files {
            board.clearContents()
            board.writeObjects([file as NSURL])
            guard await pasteMenu() else { return .notDone("WhatsApp for Mac's Paste wasn't available") }
            // The preview sheet takes Return as Send.
            try? await Task.sleep(for: .milliseconds(800))
            key(36)
            try? await Task.sleep(for: .milliseconds(800))
        }
        guard !text.isEmpty else { return .done("") }
        _ = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        board.clearContents()
        board.setString(text, forType: .string)
        guard await pasteMenu() else { return .notDone("WhatsApp for Mac's Paste wasn't available") }
        if let send = await poll(2, { element(role: "AXButton", label: "Send") }) {
            return press(send) ? .done("") : .notDone("WhatsApp for Mac didn't take the press on Send")
        }
        key(36)
        return .done("")
    }

    /// Edit → Paste in WhatsApp's menu bar, once it is enabled (it is only while WhatsApp is in front).
    private func pasteMenu() async -> Bool {
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return false }
        let menuBar = bar as! AXUIElement
        guard
            let paste = await poll(
                2,
                {
                    items(in: menuBar, limit: 3000).first {
                        $0.role == "AXMenuItem" && $0.label == "Paste"
                            && Self.string($0.element, kAXEnabledAttribute) == "1"
                    }?.element
                })
        else { return false }
        return press(paste)
    }
}
