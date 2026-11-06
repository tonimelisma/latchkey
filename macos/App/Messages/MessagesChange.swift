import Foundation

/// Tapbacks, inline replies, edits, unsending, deleting, and new groups, made in Messages' own
/// window (spec 002 FR-172 to FR-178, plan D3b) and answered as done only once Messages' database
/// shows them.
extension MessagesCapability {
    static let windowQueue = NotesCapability.WindowQueue()

    static let changeActions = ["react", "unreact", "edit", "unsend", "delete", "delete_conversation", "name_group"]

    static func changeTool(
        store: @escaping StoreSource, ui: any MessagesUI, confirmWait: Duration = .seconds(5)
    ) -> ToolEntry {
        ToolEntry(
            tool: .make(
                "messages_change", title: "Change Messages",
                description: """
                    Changes messages in the Mac's Messages app, through Messages' own window in the background. \
                    action: react (message, reaction: love, like, dislike, laugh, emphasize, question; replaces your \
                    earlier tapback), unreact (message: takes your tapback back), edit (message, text: an iMessage \
                    you sent in the last 15 minutes), unsend (message: an iMessage you sent in the last 2 minutes), \
                    delete (message: from this Mac and your other devices, to Recently Deleted), \
                    delete_conversation (conversation: the whole conversation, to Recently Deleted), name_group \
                    (conversation, text: the group's new name). Message and conversation ids come from \
                    messages_find and messages_read. Needs the Mac unlocked.
                    """,
                input: [
                    "action": .enumParam(changeActions, "What to do"),
                    "message": .stringParam("The message's id, from messages_read or messages_find"),
                    "reaction": .enumParam(Tapback.allCases.map(\.rawValue), "For react: which tapback"),
                    "text": .stringParam("For edit: the message's new text; for name_group: the group's name"),
                    "conversation": .stringParam(
                        "For delete_conversation and name_group: the conversation's id, from messages_find"),
                ], required: ["action"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
            handler: { args in
                await run(store) { s in
                    try await change(args, store: s, ui: ui, confirmWait: confirmWait)
                }
            })
    }

    private static func change(_ args: JSONValue, store s: MessagesStore, ui: any MessagesUI, confirmWait: Duration)
        async throws -> ToolResult
    {
        let action = args["action"]?.stringValue ?? ""
        let text = args["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if action == "delete_conversation" || action == "name_group" {
            guard let id = args["conversation"]?.stringValue, let who = try s.identity(of: id),
                let newest = try s.latestMessage(in: id)
            else { return .text("Give a conversation's id from messages_find.", isError: true) }
            if action == "name_group" {
                guard !text.isEmpty else { return .text("Give the group's name as text.", isError: true) }
                guard try s.locate(newest)?.isGroup == true else {
                    return .text("Only a group conversation can have a name.", isError: true)
                }
            }
            if let why = ui.unavailable() { return .text("Nothing was changed. " + why, isError: true) }
            return try await windowQueue.run {
                if action == "delete_conversation" {
                    try await ui.deleteConversation(who, showing: newest)
                    let gone = await confirmed(confirmWait) { (try? s.conversationIsEmpty(id)) == true }
                    var r = ToolResult.text(
                        gone
                            ? "Deleted the conversation \(id). Messages keeps it in Recently Deleted for up to 30 days."
                            : "Messages was asked to delete the conversation \(id) but hasn't recorded it yet. Check with messages_find in a moment."
                    )
                    r.activity = "Claude deleted a conversation in Messages"
                    return r
                }
                try await ui.nameGroup(who, showing: newest, name: text)
                let named = await confirmed(confirmWait) { (try? s.groupName(id)) == text }
                var r = ToolResult.text(
                    named
                        ? "Named the group «\(text)»."
                        : "Messages was asked to name the group «\(text)» but hasn't recorded it yet.")
                r.activity = "Claude named a group in Messages"
                return r
            }
        }
        guard changeActions.contains(action) else {
            return .text("action must be one of: \(changeActions.joined(separator: ", ")).", isError: true)
        }
        guard let id = args["message"]?.stringValue, !id.isEmpty else {
            return .text("Give the message's id, from messages_read.", isError: true)
        }
        guard let m = try s.locate(id) else {
            return .text("There is no message with id \(id). Find it with messages_read.", isError: true)
        }
        let op: MessageOp
        let expected: @Sendable () -> Bool
        let start = try s.lastRow()
        switch action {
        case "react":
            guard let t = args["reaction"]?.stringValue.flatMap(Tapback.init(rawValue:)) else {
                return .text(
                    "Give reaction: one of \(Tapback.allCases.map(\.rawValue).joined(separator: ", ")).", isError: true)
            }
            if m.myReaction == t.kind { return .text("That message already has your \(t.rawValue) tapback.") }
            op = .tapback(t)
            expected = { (try? s.reactionRecorded(on: id, type: t.code, after: start)) == true }
        case "unreact":
            guard let mine = m.myReaction else {
                return .text("That message has no tapback from you to take back.", isError: true)
            }
            guard let t = Tapback.allCases.first(where: { $0.kind == mine }) else {
                return .text(
                    "Your reaction on that message is an emoji or sticker, which Latchkey can't take back.",
                    isError: true)
            }
            op = .tapback(t)
            expected = { (try? s.reactionRecorded(on: id, type: t.code + 1000, after: start)) == true }
        case "edit":
            guard !text.isEmpty else { return .text("Give the new text.", isError: true) }
            if let why = ownRecent(m, within: 15 * 60, doing: "edited") { return .text(why, isError: true) }
            op = .edit(text)
            expected = { (try? s.editRecorded(id, text: text)) == true }
        case "unsend":
            if let why = ownRecent(m, within: 2 * 60, doing: "unsent") { return .text(why, isError: true) }
            op = .unsend
            expected = { (try? s.isUnsent(id)) == true }
        default:
            op = .delete
            expected = { (try? s.isDeleted(id)) == true }
        }
        if m.laterSame > 0 { return .text(MessagesAX.ambiguous, isError: true) }
        if let why = ui.unavailable() { return .text("Nothing was changed. " + why, isError: true) }
        let target = try balloon(m, store: s)
        return try await windowQueue.run {
            try await ui.act(op, on: target)
            let done = await confirmed(confirmWait, expected)
            let about = m.text.isEmpty ? "the message" : "«\(m.text.prefix(60))»"
            let said: String
            switch action {
            case "react": said = "Put a \(args["reaction"]?.stringValue ?? "") tapback on \(about)."
            case "unreact": said = "Took back your tapback on \(about)."
            case "edit": said = "Changed \(about) to «\(text)»."
            case "unsend": said = "Unsent \(about)."
            default: said = "Deleted \(about). Messages keeps it in Recently Deleted for up to 30 days."
            }
            var r = ToolResult.text(
                done
                    ? said
                    : "Messages was asked, but hasn't recorded it yet: \(said) Check with messages_read in a moment.")
            r.activity = "Claude changed a message in Messages"
            return r
        }
    }

    /// How the window shows the message, and its conversation.
    static func balloon(_ m: MessagesStore.Located, store s: MessagesStore) throws -> BalloonTarget {
        guard let who = try s.identity(of: m.conversationID) else {
            throw MessagesStore.Failure.noSuchConversation(m.conversationID)
        }
        return BalloonTarget(
            message: m.id, text: m.text, attachmentNames: m.attachmentNames, fromMe: m.fromMe, laterSame: m.laterSame,
            conversation: who)
    }

    /// Messages edits and unsends only its owner's iMessages, for a while after sending.
    private static func ownRecent(_ m: MessagesStore.Located, within seconds: TimeInterval, doing: String) -> String? {
        if !m.fromMe { return "Only your own messages can be \(doing)." }
        if m.unsent { return "That message was already unsent." }
        if m.service != "iMessage" { return "Only iMessages can be \(doing); this one went by \(m.service)." }
        let minutes = Int(seconds / 60)
        if Date().timeIntervalSince(m.date) > seconds {
            return
                "Messages allows a message to be \(doing) only within \(minutes) minute\(minutes == 1 ? "" : "s") of sending, and this one is older."
        }
        return nil
    }

    static func confirmed(_ wait: Duration, _ check: @Sendable () -> Bool) async -> Bool {
        await poll(wait) { check() ? true : nil } ?? false
    }

    /// Looks every 250 ms until `look` finds it, up to `wait`.
    static func poll<T: Sendable>(_ wait: Duration, _ look: @Sendable () -> T?) async -> T? {
        let deadline = ContinuousClock.now + wait
        while true {
            if let hit = look() { return hit }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: sending through the window (messages_send with reply_to or people)

    /// An inline reply to one message (FR-173).
    static func reply(
        to id: String, text: String, store s: MessagesStore, ui: any MessagesUI, confirmWait: Duration
    ) async throws -> ToolResult {
        guard let m = try s.locate(id) else {
            return .text(
                "Nothing was sent: there is no message with id \(id). Find it with messages_read.", isError: true)
        }
        guard !text.isEmpty else { return .text("Give the reply's text.", isError: true) }
        if let why = ui.unavailable() {
            return .text(
                "Nothing was sent. " + why
                    + " To answer now without quoting the message, send to conversation \(m.conversationID) instead.",
                isError: true)
        }
        if m.laterSame > 0 { return .text("Nothing was sent. " + MessagesAX.ambiguous, isError: true) }
        let start = try s.lastRow()
        let target = try balloon(m, store: s)
        return try await windowQueue.run {
            try await ui.act(.reply(text), on: target)
            let outcome = await poll(confirmWait) {
                (try? s.outgoingRecorded(after: start, conversation: m.conversationID, replyingTo: id))?.outcome
            }
            let about = m.text.isEmpty ? "the message" : "«\(m.text.prefix(60))»"
            switch outcome {
            case .failed: return .text("Messages couldn't send the reply to \(about).", isError: true)
            case .sent:
                var r = ToolResult.text("Replied to \(about): «\(text)».")
                r.activity = "Claude replied to a message in Messages"
                return r
            case nil:
                var r = ToolResult.text(
                    "Messages took the reply to \(about) but hasn't confirmed sending it yet. Check with messages_read in a moment."
                )
                r.activity = "Claude replied to a message in Messages"
                return r
            }
        }
    }

    /// A new group with several people (FR-172), named when `name` is given.
    static func startGroup(
        _ people: [String], text: String, name: String?, store s: MessagesStore, contacts: any ContactsLookup,
        ui: any MessagesUI, confirmWait: Duration
    ) async throws -> ToolResult {
        guard people.count >= 2 else {
            return .text("A group needs at least two people; for one, use to.", isError: true)
        }
        guard !text.isEmpty else { return .text("A new group needs a first message as text.", isError: true) }
        var handles: [String] = []
        var labels: [String] = []
        for p in people {
            switch try resolve(p, store: s, contacts: contacts) {
            case .failure(let why): return .text(why.message, isError: true)
            case .success(let t):
                guard let h = try handle(of: t, store: s) else {
                    return .text("Nothing was sent: \(p) is a conversation, not a person.", isError: true)
                }
                handles.append(h)
                labels.append(t.label)
            }
        }
        if let why = ui.unavailable() { return .text("Nothing was sent. " + why, isError: true) }
        let start = try s.lastRow()
        let members = handles
        let names = labels.joined(separator: ", ")
        return try await windowQueue.run {
            try await ui.startGroup(members, text: text)
            let chat = await poll(confirmWait) { try? s.groupRecorded(with: members, after: start) }
            guard let chat else {
                var r = ToolResult.text(
                    "Messages took the message for a group with \(names) but hasn't confirmed sending it yet. Check with messages_find in a moment."
                )
                r.activity = "Claude started a group in Messages"
                return r
            }
            var answer = "Started a group with \(names) (conversation \(chat)): «\(text)»."
            if let name, !name.isEmpty, let newest = try s.latestMessage(in: chat), let who = try s.identity(of: chat) {
                do {
                    try await ui.nameGroup(who, showing: newest, name: name)
                    let named = await confirmed(confirmWait) { (try? s.groupName(chat)) == name }
                    answer += named ? " Named it «\(name)»." : " Asked Messages to name it «\(name)»; not recorded yet."
                } catch let p as MessagesWindowProblem {
                    answer += " It couldn't be named: \(p.message)"
                }
            }
            var r = ToolResult.text(answer)
            r.activity = "Claude started a group in Messages"
            return r
        }
    }

    /// The number or address a resolved person is reached at, for a new group.
    private static func handle(of t: Target, store s: MessagesStore) throws -> String? {
        if t.kind == "participant" { return t.id }
        // An existing one-to-one conversation: its id ends with the person's number or address.
        let parts = t.id.split(separator: ";", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1] == "-" else { return nil }
        return parts[2]
    }
}
