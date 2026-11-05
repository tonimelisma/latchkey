import AppKit
import ApplicationServices

/// What Latchkey asks WhatsApp for Mac to send (spec 012 FR-1245, FR-1246).
struct WhatsAppDesktopSend: Equatable, Sendable {
    var chat: WhatsAppChat
    /// The person's phone number, when known: their chat can then be opened by WhatsApp's own link.
    var number: String?
    var text: String
    var files: [URL]
    var replyTo: WhatsAppMessage?
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
    func react(chat: WhatsAppChat, message: WhatsAppMessage, emoji: String) async -> WhatsAppDesktopResult
    func delete(chat: WhatsAppChat, message: WhatsAppMessage, everyone: Bool) async -> WhatsAppDesktopResult
}

/// WhatsApp for Mac driven through Accessibility (plan D3b, research "WhatsApp for Mac's window",
/// 2026-11-05). WhatsApp for Mac (a Mac Catalyst app) shows its whole window to Accessibility while
/// the Mac is unlocked: chats, messages, the message menu (Reply, React, Delete), the selection bar,
/// and the delete dialog all answer AXPress and AXShowMenu with WhatsApp behind other windows. With
/// the Mac locked it shows nothing but its menu bar, so nothing works then (checked 2026-11-05).
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
        guard WAWindow(pid: app.processIdentifier).messagePane() != nil || WAWindow(pid: app.processIdentifier)
            .chatList() != nil
        else { return "WhatsApp for Mac has no window open (it may be closed or minimized)" }
        return nil
    }

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // MARK: delete (checked 2026-11-05: seven messages deleted for me, in the background)

    func delete(chat: WhatsAppChat, message: WhatsAppMessage, everyone: Bool) async -> WhatsAppDesktopResult {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        if let why = await w.open(chat, number: store()?.number(forChat: chat.id)) { return .notDone(why) }
        guard let bubble = await w.find(message) else {
            return .notDone("WhatsApp for Mac's window doesn't show that message")
        }
        guard await w.menu(on: bubble, choose: "Delete") else {
            return .notDone("WhatsApp for Mac's message menu has no Delete")
        }
        // The chat is now in selection mode with this message selected; its Delete button asks how.
        guard let selected = await w.poll(3, { w.element(role: "AXStaticText", labelHasPrefix: "1 Selected") }) else {
            await w.leaveSelection()
            return .notDone("WhatsApp for Mac didn't select the message")
        }
        _ = selected
        guard let button = w.element(role: "AXButton", label: "Delete"), w.press(button) else {
            await w.leaveSelection()
            return .notDone("WhatsApp for Mac shows no Delete button")
        }
        let want = everyone ? "for everyone" : "for me"
        guard
            let choice = await w.poll(3, {
                w.element(role: "AXButton") { $0.hasPrefix("Delete") && $0.hasSuffix(want) }
            })
        else {
            await w.leaveSelection()
            return everyone
                ? .notDone("WhatsApp no longer offers deleting it for everyone (it may be too old)")
                : .notDone("WhatsApp for Mac didn't offer Delete for me")
        }
        guard w.press(choice) else { return .notDone("WhatsApp for Mac didn't take the press") }
        // Confirmed in WhatsApp for Mac's database: gone (for me), or marked deleted (for everyone).
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let db = store() else { break }
            let now = try? db.message(chat: chat.id, key: message.key)
            if everyone ? (now == nil || now?.kind == "deleted") : now == nil {
                return .done("confirmed in its database")
            }
        }
        return .unsure("its database doesn't show the deletion yet")
    }

    // MARK: react

    func react(chat: WhatsAppChat, message: WhatsAppMessage, emoji: String) async -> WhatsAppDesktopResult {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        if let why = await w.open(chat, number: store()?.number(forChat: chat.id)) { return .notDone(why) }
        guard let bubble = await w.find(message) else {
            return .notDone("WhatsApp for Mac's window doesn't show that message")
        }
        guard await w.menu(on: bubble, choose: "React") else {
            return .notDone("WhatsApp for Mac's message menu has no React")
        }
        return await w.pickReaction(emoji, on: message)
    }

    // MARK: send

    func send(_ request: WhatsAppDesktopSend) async -> WhatsAppDesktopResult {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier)
        let started = Date()
        if let why = await w.open(request.chat, number: request.number) { return .notDone(why) }
        if let quoted = request.replyTo {
            guard let bubble = await w.find(quoted) else {
                return .notDone("WhatsApp for Mac's window doesn't show the message to reply to")
            }
            guard await w.menu(on: bubble, choose: "Reply") else {
                return .notDone("WhatsApp for Mac's message menu has no Reply")
            }
        }
        let outcome = await w.compose(text: request.text, files: request.files)
        if case .notDone = outcome { return outcome }
        // Confirmed in WhatsApp for Mac's database: a new message of the Owner's in that chat.
        let want = (request.files.isEmpty ? 0 : request.files.count) + (request.files.isEmpty ? 1 : 0)
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let db = store(),
                let recent = try? db.messages(chat: request.chat.id, before: nil, limit: max(want, 1) + 3)
            else { continue }
            let mine = recent.filter { $0.fromMe && $0.date >= started.addingTimeInterval(-5) }
            if mine.count >= want { return .done("confirmed in its database") }
        }
        return .unsure("its database doesn't show the message yet")
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
    func items(limit: Int = 6000) -> [Item] {
        var out: [Item] = []
        var queue: [(AXUIElement, Int)] = []
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement]
        {
            queue = list.map { ($0, 0) }
        }
        var i = 0
        while i < queue.count, out.count < limit {
            let (e, depth) = queue[i]
            i += 1
            let role = AppWindowReader.string(e, kAXRoleAttribute) ?? ""
            if role == "AXApplication" { continue }
            let label = Self.clean(
                AppWindowReader.string(e, kAXDescriptionAttribute) ?? AppWindowReader.string(e, kAXTitleAttribute))
            out.append(Item(element: e, role: role, label: label, value: Self.clean(AppWindowReader.string(e, kAXValueAttribute))))
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
    func messagePane() -> Item? { items().first { $0.role == "AXGroup" && $0.label.hasPrefix("Messages in chat with") } }

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

    /// Opens a chat without bringing WhatsApp forward: by its row in the chat list (scrolled to when
    /// needed), or, for a person whose number is known, by WhatsApp's own link. Nil when it is open.
    func open(_ chat: WhatsAppChat, number: String?) async -> String? {
        let name = chat.name
        if isOpen(name) { return nil }
        if let row = await findRow(name) {
            press(row)
            if await poll(3, { isOpen(name) ? true : nil }) != nil { return nil }
        }
        if let number, !chat.isGroup, let url = URL(string: "whatsapp://send?phone=\(number)") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.open(url, configuration: config)
            if await poll(5, { messagePane() != nil && isOpen(name) ? true : nil }) != nil { return nil }
            // The Owner's own chat is named for them in the header; the link opened the right one.
            if await poll(2, { messagePane() != nil ? true : nil }) != nil, name == "You" { return nil }
        }
        return "WhatsApp for Mac shows no chat named \(MessagesCapability.quote(name)) in its list"
    }

    func isOpen(_ name: String) -> Bool {
        guard let pane = messagePane() else { return false }
        return Self.clean(String(pane.label.dropFirst("Messages in chat with".count))) == name
    }

    /// The chat list's row for `name`, scrolling down the list a page at a time, then back to the top.
    func findRow(_ name: String) async -> AXUIElement? {
        guard let list = chatList() else { return nil }
        let rowName = { (label: String) in label.components(separatedBy: ",").first.map(Self.clean) ?? "" }
        for _ in 0..<25 {
            if let row = items().first(where: { $0.role == "AXButton" && rowName($0.label) == name }) {
                return row.element
            }
            guard perform(list, "AXScrollDownByPage") else { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// A message's bubble in the open chat: its text (or file name) and time, scrolling up for older ones.
    func find(_ m: WhatsAppMessage) async -> AXUIElement? {
        let time = m.date.formatted(
            .verbatim(
                "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: .current, calendar: .current))
        let words = Self.clean(m.text.isEmpty ? (m.fileName ?? "") : m.text)
        let start = m.fromMe ? "Your " : ""
        for _ in 0..<30 {
            let hits = items().filter {
                $0.role == "AXStaticText" && $0.label.hasPrefix(start) && $0.label.contains(", ")
                    && (words.isEmpty || $0.label.contains(words)) && $0.label.contains(time)
            }
            if hits.count == 1 {
                _ = perform(hits[0].element, "AXScrollToVisible")
                try? await Task.sleep(for: .milliseconds(200))
                return hits[0].element
            }
            if hits.count > 1 { return nil }
            guard let pane = messagePane(), perform(pane.element, "AXScrollUpByPage") else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
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
            let role = AppWindowReader.string(e, kAXRoleAttribute) ?? ""
            if role == "AXMenuBar" || (role == "AXApplication" && depth > 0) { continue }
            if role == "AXMenuItem" {
                out.append(
                    Item(element: e, role: role, label: Self.clean(AppWindowReader.string(e, kAXTitleAttribute)), value: ""))
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
            if let parent = AppWindowReader.parent(item.element) { _ = perform(parent, "AXCancel") }
        }
        PidPoster(pid: pid).post(.key(53, down: true, []))
        PidPoster(pid: pid).post(.key(53, down: false, []))
    }

    /// Leaves the selection mode Delete opened, without deleting.
    func leaveSelection() async {
        if let cancel = element(role: "AXButton", label: "Cancel") { press(cancel) }
    }

    /// After the message menu's React: the emoji, from the quick row or WhatsApp's own picker.
    func pickReaction(_ emoji: String, on m: WhatsAppMessage) async -> WhatsAppDesktopResult {
        let target = emoji.isEmpty ? nil : emoji
        guard
            let button = await poll(3, {
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
        .notDone("WhatsApp for Mac can't be typed into from the background")
    }
}
