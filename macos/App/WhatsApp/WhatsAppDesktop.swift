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

    /// The open chat's bubble for the message, after opening the chat with certainty.
    private func bubble(_ w: WAWindow, _ target: WhatsAppDesktopTarget, _ m: WhatsAppMessage) async -> Result<
        AXUIElement, WAWindow.Refusal
    > {
        if let why = await w.open(target) { return .failure(WAWindow.Refusal(message: why)) }
        return await w.find(m)
    }

    // MARK: delete (checked live 2026-11-05: in WhatsApp's own selection mode and dialog)

    func delete(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, everyone: Bool) async
        -> WhatsAppDesktopResult
    {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier, chat: target.isSelf ? "You" : target.chat.name)
        let found: AXUIElement
        switch await bubble(w, target, message) {
        case .failure(let p): return .notDone(p.message)
        case .success(let b): found = b
        }
        // The message menu brings WhatsApp forward (checked 2026-11-05), so it is used only while
        // the Owner isn't typing or pointing, and the app they were in comes back afterwards.
        let pressed = await w.briefly(menuFirst: true) { () async -> WhatsAppDesktopResult in
            guard await w.menu(on: found, choose: "Delete") else {
                return .notDone("WhatsApp for Mac's message menu has no Delete")
            }
            // Selection mode, with exactly this message selected.
            let selected = await w.poll(3) { () -> Bool? in
                guard w.element(role: "AXStaticText", label: "1 Selected") != nil,
                    let pane = w.messagePane(), w.isTarget(pane)
                else { return nil }
                let bubbles = w.items(in: pane.element).filter { $0.role == "AXStaticText" }
                let mine = bubbles.filter { WAWindow.matches($0.label, message) }
                // A text bubble says "Selected" (seen 2026-11-05); a document's didn't, so then no other
                // bubble may say it either, and "1 Selected" is the menu's own message.
                let marked = bubbles.filter { $0.value == "Selected" }
                guard mine.count == 1 else { return nil }
                if marked.isEmpty { return true }
                return marked.count == 1 && WAWindow.matches(marked[0].label, message) ? true : nil
            }
            guard selected == true else {
                await w.leaveSelection()
                return .notDone("WhatsApp for Mac didn't select that message alone")
            }
            guard let area = w.chatArea(),
                let button = w.items(in: area).first(where: {
                    $0.role == "AXButton" && $0.label == "Delete"
                })?.element, w.press(button)
            else {
                await w.leaveSelection()
                return .notDone("WhatsApp for Mac shows no Delete button")
            }
            let want = everyone ? "for everyone" : "for me"
            guard
                let choice = await w.poll(
                    3, { w.element(role: "AXButton") { $0.hasPrefix("Delete") && $0.hasSuffix(want) } })
            else {
                w.key(53)
                await w.leaveSelection()
                return everyone
                    ? .notDone(
                        "WhatsApp doesn't offer deleting it for everyone (too old, or not in this chat, as in your own)"
                    )
                    : .notDone("WhatsApp for Mac didn't offer Delete for me")
            }
            return await w.pressAndSettle(choice)
        }
        guard case .done = pressed else { return pressed }
        // That very message (by its id) gone (for me), or marked deleted (for everyone).
        let gone = await confirm { db in
            let now = try? db.message(chat: target.chat.id, key: message.key)
            return everyone ? (now == nil || now?.kind == "deleted") : now == nil
        }
        return gone ? .done("confirmed in its database") : .unsure("its database doesn't show that message deleted")
    }

    // MARK: react (checked live 2026-11-05: WhatsApp's tray of twelve; the Owner's own is marked selected)

    func react(_ target: WhatsAppDesktopTarget, message: WhatsAppMessage, emoji: String) async
        -> WhatsAppDesktopResult
    {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let w = WAWindow(pid: app.processIdentifier, chat: target.isSelf ? "You" : target.chat.name)
        let before = store()?.stamp(chat: target.chat.id, key: message.key)
        let found: AXUIElement
        switch await bubble(w, target, message) {
        case .failure(let p): return .notDone(p.message)
        case .success(let b): found = b
        }
        let picked = await w.briefly(menuFirst: true) { () async -> WhatsAppDesktopResult in
            guard await w.menu(on: found, choose: "React") else {
                return .notDone("WhatsApp for Mac's message menu has no React")
            }
            return await w.pickReaction(emoji)
        }
        guard case .done(let how) = picked else { return picked }
        if !how.isEmpty { return picked }
        // That very message (by its id) changed in the database; a reaction made in WhatsApp for Mac
        // itself wasn't in its database (2026-11-05), so the chat list's own line about it counts too.
        let changed = await confirm { db in
            let now = db.stamp(chat: target.chat.id, key: message.key)
            return now != nil && now != before
        }
        if changed { return .done("confirmed in its database") }
        let words = WAWindow.clean(message.text.isEmpty ? (message.fileName ?? "") : message.text)
        if await w.poll(2, { w.reactionShown(emoji, words) ? true : nil }) != nil {
            return .done("WhatsApp for Mac's chat list shows it")
        }
        return .unsure("neither its database nor its chat list shows it")
    }

    // MARK: send (checked live 2026-11-05)

    func send(_ request: WhatsAppDesktopSend) async -> WhatsAppDesktopResult {
        guard let app = Self.app() else { return .notDone("WhatsApp for Mac isn't running") }
        let target = request.target
        let w = WAWindow(pid: app.processIdentifier, chat: target.isSelf ? "You" : target.chat.name)
        let started = Date()
        if let why = await w.open(target) { return .notDone(why) }
        var quotedBubble: AXUIElement?
        if let quoted = request.replyTo {
            switch await w.find(quoted) {
            case .failure(let p): return .notDone(p.message)
            case .success(let b): quotedBubble = b
            }
        }
        let outcome: WhatsAppDesktopResult
        if request.files.isEmpty, quotedBubble == nil, let number = target.number, !target.chat.isGroup {
            // A person (or the Owner's own chat) and text alone: all in the background, through
            // WhatsApp's own link with the text, then Send.
            outcome = await w.sendByLink(number: number, text: request.text)
        } else {
            outcome = await w.briefly(menuFirst: quotedBubble != nil) { () async -> WhatsAppDesktopResult in
                if let quotedBubble, let quoted = request.replyTo {
                    guard await w.menu(on: quotedBubble, choose: "Reply") else {
                        return .notDone("WhatsApp for Mac's message menu has no Reply")
                    }
                    guard await w.poll(2, { w.quoting(quoted) ? true : nil }) != nil else {
                        return .notDone("WhatsApp for Mac didn't show the reply to that message")
                    }
                }
                return await w.typeAndSend(text: request.text, files: request.files)
            }
        }
        if case .notDone = outcome { return outcome }
        // A new message of the Owner's in that chat (by its id), with the text or a file; a reply
        // must quote the message by its id.
        let wanted = request.files.count + (request.text.isEmpty ? 0 : 1)
        let text = WhatsAppStore.clean(request.text) ?? ""
        let sent = await confirm { db in
            guard let recent = try? db.messages(chat: request.chat.id, before: nil, limit: wanted + 5) else {
                return false
            }
            let mine = recent.filter { $0.fromMe && $0.date >= started.addingTimeInterval(-5) }
            let withText = text.isEmpty || mine.contains { $0.text == text }
            let quotes =
                request.replyTo.map { q in
                    mine.contains { db.quotes(chat: request.chat.id, key: $0.key, quoted: q.key) }
                }
                ?? true
            return mine.count >= wanted && withText && quotes
        }
        return sent ? .done("confirmed in its database") : .unsure("its database doesn't show the message yet")
    }
}

/// WhatsApp for Mac's window through Accessibility, for one chat. Its labels start with an
/// invisible direction mark (U+200E), which every comparison here removes.
struct WAWindow: @unchecked Sendable {
    let pid: pid_t
    let app: AXUIElement
    /// The chat this window is used for, as its header names it ("You" for the Owner's own).
    let chat: String

    init(pid: pid_t, chat: String = "") {
        self.pid = pid
        self.chat = chat
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
    }

    struct Item {
        var element: AXUIElement
        var role: String
        var label: String
        var value: String
    }

    struct Refusal: Error { var message: String }

    static func clean(_ s: String?) -> String { WhatsAppStore.clean(s) ?? "" }

    /// Every element under `root` (the window by default), once. While the Mac is locked WhatsApp
    /// lists itself as its own child; that loop is cut.
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

    func element(role: String, where test: (String) -> Bool) -> AXUIElement? {
        items().first { $0.role == role && test($0.label) }?.element
    }

    func chatList() -> AXUIElement? { element(role: "AXGroup", label: "List of chats") }

    /// The open chat's messages, labelled "Messages in chat with <name>".
    func messagePane() -> Item? {
        items().first { $0.role == "AXGroup" && $0.label.hasPrefix("Messages in chat with") }
    }

    static func paneName(_ label: String) -> String { clean(String(label.dropFirst("Messages in chat with".count))) }

    /// The open chat is this window's chat.
    func isTarget(_ pane: Item) -> Bool { !chat.isEmpty && Self.paneName(pane.label) == chat }

    /// The part of the window for the open chat: its messages, message box, and bars (the nearest
    /// ancestor of the messages that holds the message box, or the selection bar that replaces it,
    /// but not the chat list).
    func chatArea() -> AXUIElement? {
        guard let pane = messagePane(), isTarget(pane) else { return nil }
        var current = WAWindow.parent(pane.element)
        for _ in 0..<6 {
            guard let c = current else { return nil }
            let inside = items(in: c, limit: 4000)
            if inside.contains(where: { $0.role == "AXGroup" && $0.label == "List of chats" }) { return nil }
            if inside.contains(where: {
                ($0.role == "AXTextArea" && $0.label == "Compose message")
                    || ($0.role == "AXStaticText" && $0.label.hasSuffix(" Selected"))
            }) {
                return c
            }
            current = WAWindow.parent(c)
        }
        return nil
    }

    /// The message box of this window's chat, looked up again inside it each time.
    func composeBox() -> AXUIElement? {
        guard let area = chatArea() else { return nil }
        return items(in: area).first { $0.role == "AXTextArea" && $0.label == "Compose message" }?.element
    }

    func sendButton() -> AXUIElement? {
        guard let area = chatArea() else { return nil }
        return items(in: area).first { $0.role == "AXButton" && $0.label == "Send" }?.element
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

    // MARK: opening a chat with certainty (security review 2026-11-05)

    /// Opens the target's chat without bringing WhatsApp forward. First it leaves whatever chat is
    /// open (Chat → Close Chat), so the header can only name the chat this call opens; then a person,
    /// or the Owner's own chat, by WhatsApp's own link for the number, else the chat list's only row
    /// with that name (archived chats looked at too). The Owner's own chat is taken as such only when
    /// no chat in the lists is named You. Nil when it is open; otherwise why not.
    func open(_ target: WhatsAppDesktopTarget) async -> String? {
        guard target.nameIsUnique else {
            return
                "another chat in WhatsApp for Mac has the same name, «\(target.chat.name)», so its window can't tell them apart"
        }
        guard !chat.isEmpty else { return "no chat to open" }
        var row: RowPlace?
        if target.isSelf {
            guard target.number != nil else { return "the Owner's own number isn't known to WhatsApp for Mac" }
            guard await rows(named: "You").isEmpty else {
                return "a chat in WhatsApp for Mac is named You, so the Owner's own chat can't be told apart"
            }
        } else if target.number == nil || target.chat.isGroup {
            let found = await rows(named: chat)
            guard found.count == 1 else {
                return "WhatsApp for Mac's chat lists don't show exactly one chat named «\(chat)»"
            }
            row = found[0]
        }
        guard await leaveChat() else { return "WhatsApp for Mac didn't close the chat it showed" }
        if let row {
            guard await pressRow(row) else { return "WhatsApp for Mac's chat list lost the row of «\(chat)»" }
        } else if let number = target.number {
            guard let url = URL(string: "whatsapp://send?phone=\(number)") else { return "that number isn't usable" }
            await openLink(url)
        }
        if await poll(5, { messagePane().map(isTarget) == true ? true : nil }) != nil { return nil }
        return "WhatsApp for Mac didn't open the chat with «\(target.chat.name)»"
    }

    func openLink(_ url: URL) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.open(url, configuration: config)
    }

    /// Chat → Close Chat from the menu bar (works with WhatsApp behind), until no chat is open.
    func leaveChat() async -> Bool {
        guard messagePane() != nil else { return true }
        guard let close = menuBarItem("Close Chat"), press(close) else { return false }
        return await poll(3, { messagePane() == nil ? true : nil }) != nil
    }

    /// A chat row's name: its label up to the first comma ("Family, 3 unread messages").
    static func rowName(_ label: String) -> String { label.components(separatedBy: ",").first.map(clean) ?? "" }

    enum RowPlace { case main, archived }

    /// Every row named `name` in the chat list and in Archived, looking through each list a page at a
    /// time; the main list shows again afterwards.
    func rows(named name: String) async -> [RowPlace] {
        var out: [RowPlace] = []
        if let list = chatList() {
            out += Array(repeating: .main, count: await count(name, in: list))
        }
        if let archived = items().first(where: { $0.role == "AXButton" && $0.label == "Archived" })?.element,
            press(archived)
        {
            try? await Task.sleep(for: .milliseconds(400))
            if let list = archivedList() { out += Array(repeating: .archived, count: await count(name, in: list)) }
            await showChats()
        }
        return out
    }

    /// The Archived view's list: the group whose rows offer Unarchive.
    func archivedList() -> AXUIElement? {
        for row in items() where row.role == "AXButton" && WAWindow.actions(row.element).contains("Unarchive") {
            return WAWindow.parent(row.element)
        }
        return nil
    }

    func showChats() async {
        if let chats = items().first(where: { $0.role == "AXStaticText" && $0.label.hasPrefix("Chats") })?.element {
            press(chats)
            _ = await poll(2, { chatList() })
        }
    }

    /// How many rows of a list are named `name`, scrolled through and back to the top.
    func count(_ name: String, in list: AXUIElement) async -> Int {
        var found: [AXUIElement] = []
        var lastPage: [String] = []
        for _ in 0..<40 {
            let rows = items(in: list).filter { $0.role == "AXButton" && !$0.label.isEmpty && $0.label != "Archived" }
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
            let page = items(in: list).filter { $0.role == "AXButton" }.map(\.label)
            if page == lastPage { break }
            lastPage = page
        }
        return found.count
    }

    /// Presses the one row named for this window's chat, in its list.
    func pressRow(_ place: RowPlace) async -> Bool {
        var list: AXUIElement? = chatList()
        if place == .archived {
            guard let archived = items().first(where: { $0.role == "AXButton" && $0.label == "Archived" })?.element,
                press(archived)
            else { return false }
            list = await poll(2, { archivedList() })
        }
        guard let list else { return false }
        for _ in 0..<40 {
            let rows = items(in: list).filter { $0.role == "AXButton" && Self.rowName($0.label) == chat }
            if rows.count == 1 { return press(rows[0].element) }
            guard rows.isEmpty, perform(list, "AXScrollDownByPage") else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    // MARK: finding a message (security review 2026-11-05: fields, not substrings)

    /// The words a bubble shows for a message: a document's file name ("Your document, check.txt,
    /// …"), else its text or caption.
    static func shownWords(_ m: WhatsAppMessage) -> String {
        if m.kind == "document", let f = m.fileName, !clean(f).isEmpty { return clean(f) }
        return clean(m.text.isEmpty ? (m.fileName ?? "") : m.text)
    }

    /// A bubble's own line: a reply's label is "Replying to X.\n<the reply's line>.\nQuoted
    /// message.\n<the quoted words>" (checked 2026-11-05); only the reply's line is its own.
    static func ownLine(_ label: String) -> String {
        let lines = label.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].hasPrefix("Replying to ") else { return label }
        var line = lines[1]
        if line.hasSuffix(".") { line.removeLast() }
        return line
    }

    /// The date and time a bubble shows: "21:22" today, "November 4, at 21:22" this year, else with
    /// the year (as WhatsApp for Mac labelled them on 2026-11-05).
    static func when(_ date: Date, now: Date) -> String {
        let english = Locale(identifier: "en_US_POSIX")
        let time = date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: .current, calendar: .current))
        if Calendar.current.isDate(date, inSameDayAs: now) { return time }
        let day = date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(month: .wide) \(day: .defaultDigits)", locale: english, timeZone: .current,
                calendar: .current))
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) { return "\(day), at \(time)" }
        let year = date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)", locale: english, timeZone: .current, calendar: .current))
        return "\(day), \(year), at \(time)"
    }

    /// Whether a bubble's label is this message's, field by field: "Your <kind>" for the Owner's own
    /// or "<Kind> from <sender>" for others', then exactly its words (or file name), then exactly its
    /// date and time, then the end or the next field.
    static func matches(_ label: String, _ m: WhatsAppMessage, now: Date = Date()) -> Bool {
        let words = shownWords(m)
        guard !words.isEmpty else { return false }
        let line = ownLine(label)
        let tail = ", \(words), \(when(m.date, now: now))"
        guard let range = line.range(of: tail) else { return false }
        let after = line[range.upperBound...]
        guard after.isEmpty || after.hasPrefix(",") else { return false }
        let head = String(line[..<range.lowerBound])
        if m.fromMe {
            return head.range(of: #"^Your [a-z]+( [a-z]+)?$"#, options: .regularExpression) != nil
        }
        return !head.hasPrefix("Your ")
            && head.range(of: #"^[A-Z][a-z]+( [a-z]+)? from \S"#, options: .regularExpression) != nil
    }

    /// The message's bubble in this window's chat, scrolling up for older ones. Refused when the
    /// message has no words or file name, or when more than one bubble matches.
    func find(_ m: WhatsAppMessage) async -> Result<AXUIElement, Refusal> {
        guard !(m.text.isEmpty && (m.fileName ?? "").isEmpty) else {
            return .failure(
                Refusal(message: "that message has no words or file name WhatsApp for Mac's window can be matched on"))
        }
        for _ in 0..<30 {
            guard let pane = messagePane(), isTarget(pane) else {
                return .failure(Refusal(message: "WhatsApp for Mac's window changed to another chat"))
            }
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

    /// The message box shows that it replies to this message ("Quoted message, <its line>").
    func quoting(_ m: WhatsAppMessage) -> Bool {
        guard let area = chatArea() else { return false }
        return items(in: area).contains {
            $0.role == "AXTextArea" && $0.label.hasPrefix("Quoted message, ")
                && Self.matchesQuote(String($0.label.dropFirst("Quoted message, ".count)), m)
        }
    }

    /// A quote panel names the side and words without the time ("Your message, <words>").
    static func matchesQuote(_ text: String, _ m: WhatsAppMessage) -> Bool {
        let words = shownWords(m)
        guard !words.isEmpty, text.hasSuffix(", \(words)") else { return false }
        let head = String(text.dropLast(", \(words)".count))
        return m.fromMe
            ? head.range(of: #"^Your [a-z]+( [a-z]+)?$"#, options: .regularExpression) != nil
            : !head.hasPrefix("Your ")
    }

    // MARK: menus

    /// Opens an element's menu (AXShowMenu) and chooses an item by its title; closes it otherwise.
    func menu(on e: AXUIElement, choose title: String) async -> Bool {
        guard perform(e, "AXShowMenu") else { return false }
        let item = await poll(2) { menuItems().first { Self.clean($0.label) == title }?.element }
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

    /// An item of WhatsApp's menu bar by its title.
    func menuBarItem(_ title: String) -> AXUIElement? {
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }
        return items(in: (bar as! AXUIElement), limit: 3000).first { $0.role == "AXMenuItem" && $0.label == title }?
            .element
    }

    func closeMenus() {
        for item in menuItems() {
            if let parent = WAWindow.parent(item.element) { _ = perform(parent, "AXCancel") }
        }
        key(53)
    }

    /// Leaves the selection mode Delete opened, without deleting.
    func leaveSelection() async {
        if let cancel = element(role: "AXButton", label: "Cancel") { press(cancel) }
    }

    /// After the message menu's React: WhatsApp's tray of twelve reactions, the Owner's own marked
    /// selected. React presses the emoji (not again when it is already the Owner's); unreact presses
    /// the selected one. Answers done("…") when nothing needed changing.
    func pickReaction(_ emoji: String) async -> WhatsAppDesktopResult {
        let tray = await poll(3) { () -> [Item]? in
            let found = items().filter {
                $0.role == "AXButton" && WAWindow.string($0.element, "AXIdentifier") == "ReactionsTray_ReactionButton"
            }
            return found.isEmpty ? nil : found
        }
        // The tray opens with a short animation; a press during it is dropped (2026-11-05).
        try? await Task.sleep(for: .milliseconds(600))
        guard let tray else {
            closeMenus()
            return .notDone("WhatsApp for Mac didn't show its reactions")
        }
        let mine = tray.first { WAWindow.string($0.element, kAXSelectedAttribute) == "1" }
        if emoji.isEmpty {
            guard let mine else {
                closeMenus()
                return .done("there was no reaction of yours to take off")
            }
            return await pressAndSettle(mine.element)
        }
        if let mine, mine.label == emoji {
            closeMenus()
            return .done("it already had that reaction of yours")
        }
        guard let button = tray.first(where: { $0.label == emoji }) else {
            closeMenus()
            return .notDone(
                "WhatsApp for Mac's reactions offer only \(tray.map(\.label).joined(separator: " ")); its picker for others isn't used"
            )
        }
        return await pressAndSettle(button.element)
    }

    /// The chat list says the Owner's reaction (or none, for an empty emoji) on a message with these
    /// words: "You reacted 👍 to "<words>"" (seen 2026-11-05).
    func reactionShown(_ emoji: String, _ words: String) -> Bool {
        guard let list = chatList(), !words.isEmpty else { return false }
        let start = String(words.prefix(30))
        let lines = items(in: list).map(\.value)
        if emoji.isEmpty { return !lines.contains { $0.hasPrefix("You reacted ") && $0.contains("to \"\(start)") } }
        return lines.contains { $0.hasPrefix("You reacted \(emoji) to \"\(start)") }
    }

    /// Presses, then waits for what was pressed to go away (a tray, a dialog) and a moment more:
    /// bringing the Owner's app back sooner made WhatsApp drop a reaction (2026-11-05).
    func pressAndSettle(_ e: AXUIElement) async -> WhatsAppDesktopResult {
        guard press(e) else { return .notDone("WhatsApp for Mac didn't take the press") }
        _ = await poll(2, { WAWindow.string(e, kAXRoleAttribute) == nil ? true : nil })
        try? await Task.sleep(for: .milliseconds(700))
        return .done("")
    }

    // MARK: typing and sending

    /// Text to a person (or the Owner's own chat) with WhatsApp behind: WhatsApp's own link fills the
    /// box (checked 2026-11-05), then the chat and the box's exact text are checked before Send.
    func sendByLink(number: String, text: String) async -> WhatsAppDesktopResult {
        var parts = URLComponents()
        parts.scheme = "whatsapp"
        parts.host = "send"
        parts.queryItems = [URLQueryItem(name: "phone", value: number), URLQueryItem(name: "text", value: text)]
        guard let url = parts.url else { return .notDone("that text can't go in WhatsApp's link") }
        await openLink(url)
        let ready = await poll(5) { () -> AXUIElement? in
            guard let pane = messagePane(), isTarget(pane), let box = composeBox(),
                Self.clean(WAWindow.string(box, kAXValueAttribute)) == Self.clean(text)
            else { return nil }
            return sendButton()
        }
        guard let ready else {
            clearBox()
            return .notDone("WhatsApp for Mac's message box didn't hold exactly that text in that chat")
        }
        return press(ready) ? .done("") : .notDone("WhatsApp for Mac didn't take the press on Send")
    }

    /// Empties the message box, so nothing half-done waits in it.
    func clearBox() {
        if let box = composeBox() {
            _ = AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, "" as CFString)
        }
    }

    /// With WhatsApp in front: each file pasted (it opens WhatsApp's preview, sent with its Send),
    /// then the text typed and sent. Before every paste, keystroke, and press: still this chat, still
    /// in front, and the Owner hasn't touched the keyboard or pointer.
    func typeAndSend(text: String, files: [URL]) async -> WhatsAppDesktopResult {
        for file in files {
            if let why = await ready() { return .notDone(why) }
            guard let box = composeBox() else { return .notDone("WhatsApp for Mac shows no message box") }
            press(box)
            guard await pasteFile(file) else { return .notDone("WhatsApp for Mac didn't take the file") }
            guard
                let send = await poll(
                    3,
                    {
                        items().first(where: { $0.role == "AXTextArea" && $0.label == "Caption text field" }) != nil
                            ? items().first { $0.role == "AXButton" && $0.label == "Send" }?.element : nil
                    })
            else { return .notDone("WhatsApp for Mac didn't show the file to send") }
            if let why = await ready(preview: true) {
                if let cancel = element(role: "AXButton", label: "Cancel") { press(cancel) }
                return .notDone(why)
            }
            guard press(send) else { return .notDone("WhatsApp for Mac didn't take the press on Send") }
            _ = await poll(3, { element(role: "AXTextArea", label: "Caption text field") == nil ? true : nil })
        }
        guard !text.isEmpty else { return .done("") }
        if let why = await ready() { return .notDone(why) }
        guard let box = composeBox(), Self.clean(WAWindow.string(box, kAXValueAttribute)).isEmpty else {
            return .notDone("WhatsApp for Mac's message box isn't empty")
        }
        press(box)
        var rest = Array(text.utf16)[...]
        while !rest.isEmpty {
            if let why = await ready() {
                clearBox()
                return .notDone(why)
            }
            let chunk = Array(rest.prefix(32))
            rest = rest.dropFirst(chunk.count)
            typeChunk(chunk)
            try? await Task.sleep(for: .milliseconds(30))
        }
        let send = await poll(3) { () -> AXUIElement? in
            guard let box = composeBox(), Self.clean(WAWindow.string(box, kAXValueAttribute)) == Self.clean(text)
            else { return nil }
            return sendButton()
        }
        guard let send, await ready() == nil else {
            clearBox()
            return .notDone("WhatsApp for Mac's message box didn't hold exactly that text, so nothing was sent")
        }
        return await pressAndSettle(send)
    }

    /// Nil when it is safe to go on: this window's chat is open (or its file preview), WhatsApp is in
    /// front, and nobody used the keyboard or pointer since Latchkey's own last keystroke.
    func ready(preview: Bool = false) async -> String? {
        guard WAWindow.isFront(pid) else {
            return "another app came to the front"
        }
        if WAWindow.ownerActed(since: lastOwn.value) { return "the Mac's owner started using the keyboard or pointer" }
        if !preview, messagePane().map(isTarget) != true { return "WhatsApp for Mac's window changed to another chat" }
        return nil
    }

    /// When Latchkey last typed into WhatsApp (its own keystrokes count as input to macOS too).
    let lastOwn = Locked<Date>(.distantPast)

    /// The keyboard or pointer was used more recently than Latchkey's own last keystroke, and in the
    /// last 3 seconds.
    static func ownerActed(since own: Date, idle: Double = WAWindow.idleSeconds()) -> Bool {
        let sinceOwn = Date().timeIntervalSince(own)
        return idle < 3 && idle + 0.15 < sinceOwn
    }

    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Typed through the session's event stream: WhatsApp takes no keys sent to it alone
    /// (checked 2026-11-05), so this goes only while it is in front (`ready`).
    private func typeChunk(_ units: [UInt16]) {
        let source = CGEventSource(stateID: .privateState)
        lastOwn.mutate { $0 = Date() }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cgSessionEventTap)
        }
        lastOwn.mutate { $0 = Date() }
    }

    /// Command-V with the file on the clipboard; the Owner's clipboard is put back.
    private func pasteFile(_ file: URL) async -> Bool {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        board.clearContents()
        board.writeObjects([file as NSURL])
        let source = CGEventSource(stateID: .privateState)
        lastOwn.mutate { $0 = Date() }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
        lastOwn.mutate { $0 = Date() }
        let shown = await poll(3, { element(role: "AXTextArea", label: "Caption text field") != nil ? true : nil })
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
        return shown != nil
    }

    /// Brings WhatsApp forward for `body` (its message menu and typing need it; checked 2026-11-05),
    /// only when the Owner hasn't used the keyboard or pointer in the last 3 seconds, then brings back
    /// the app that was in front.
    /// With `menuFirst`, the body's first step opens a message's menu, which brings WhatsApp forward
    /// by itself (checked 2026-11-05); otherwise WhatsApp is brought forward first.
    func briefly(menuFirst: Bool = false, _ body: () async -> WhatsAppDesktopResult) async -> WhatsAppDesktopResult {
        guard let whatsapp = NSRunningApplication(processIdentifier: pid) else {
            return .notDone("WhatsApp for Mac isn't running")
        }
        guard WAWindow.idleSeconds() >= 3 else {
            return .notDone(
                "the Mac's owner is using the keyboard or pointer, and WhatsApp for Mac would have to come to the front; try again in a moment"
            )
        }
        let previous = NSWorkspace.shared.frontmostApplication
        lastOwn.mutate { $0 = Date() }
        if !menuFirst, await bringWhatsAppForward(whatsapp) == false {
            return .notDone("WhatsApp for Mac didn't come to the front")
        }
        let result = await body()
        if let previous, previous.processIdentifier != pid {
            previous.activate()
            WAWindow.bringForward(previous.processIdentifier)
            _ = await poll(
                1, { WAWindow.isFront(previous.processIdentifier) ? true : nil })
        }
        return result
    }

    /// macOS grants another app's activation to a program in the background late or not at all
    /// (cooperative activation; seen 2026-11-05 from a command-line program: WhatsApp came forward
    /// only after it had ended). WhatsApp brings itself forward when a message's menu opens (checked
    /// 2026-11-05), so that is the fallback: the menu of the chat's latest message, closed at once.
    private func bringWhatsAppForward(_ whatsapp: NSRunningApplication) async -> Bool {
        let isFront = { WAWindow.isFront(pid) ? true : nil }
        whatsapp.activate()
        WAWindow.bringForward(pid)
        if await poll(0.8, isFront) != nil { return true }
        guard let pane = messagePane(), isTarget(pane),
            let latest = items(in: pane.element).last(where: { $0.role == "AXStaticText" && $0.label.contains(", ") })
        else { return false }
        _ = perform(latest.element, "AXShowMenu")
        let front = await poll(2, isFront) != nil
        _ = await poll(1, { menuItems().isEmpty ? nil : true })
        closeMenus()
        _ = await poll(1, { menuItems().isEmpty ? true : nil })
        return front
    }

    // MARK: Accessibility helpers

    /// Whether the app is in front, as the app itself tells Accessibility (NSWorkspace's answer lagged
    /// in a program without its own app loop, 2026-11-05).
    static func isFront(_ pid: pid_t) -> Bool {
        var v: AnyObject?
        guard
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &v)
                == .success
        else { return false }
        return (v as? Bool) == true || (v as? NSNumber)?.boolValue == true
    }

    static func bringForward(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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

    /// An element's actions, named ones by their names ("Unarchive").
    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return ((names as? [String]) ?? []).map {
            $0.hasPrefix("Name:") ? clean(String($0.dropFirst(5).prefix { $0 != "\n" })) : $0
        }
    }
}
