import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// Plays Messages' window: records what Latchkey asked for, and writes to the fixture database
/// what Messages would record.
final class FakeMessagesUI: MessagesUI, @unchecked Sendable {
    private let lock = NSLock()
    var reason: String?
    var effect: @Sendable (String) -> Void = { _ in }
    private(set) var calls: [String] = []
    private(set) var targets: [BalloonTarget] = []

    private func record(_ s: String) {
        lock.withLock { calls.append(s) }
        effect(s)
    }

    func unavailable() -> String? { reason }
    func act(_ op: MessageOp, on target: BalloonTarget) async throws {
        record("\(op) \(target.message) «\(target.text)» \(target.fromMe ? "mine" : "theirs") \(target.laterSame)")
        lock.withLock { targets.append(target) }
    }
    func deleteConversation(_ c: ConversationIdentity, showing message: String) async throws {
        record("delete conversation \(c.id) of \(message)")
    }
    func startGroup(_ handles: [String], text: String) async throws {
        record("group \(handles.joined(separator: ",")) «\(text)»")
    }
    func nameGroup(_ c: ConversationIdentity, showing message: String, name: String) async throws {
        record("name \(c.id) \(message) «\(name)»")
    }
}

@Suite struct MessagesChangeTests {
    struct Setup {
        var db: URL
        var ui: FakeMessagesUI
        var tools: [String: ToolEntry]
    }

    func setup() throws -> Setup {
        let db = try MessagesFixture.make()
        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let ui = FakeMessagesUI()
        let tools = MessagesCapability.writeOperations(
            store: { store }, contacts: MessagesFixture.FakeContacts(), scripts: FakeScripts(),
            staging: FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)"), ui: ui,
            confirmWait: .milliseconds(600))
        return Setup(db: db, ui: ui, tools: Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) }))
    }

    static func exec(_ db: URL, _ sql: String) {
        var h: OpaquePointer?
        sqlite3_open(db.path, &h)
        defer { sqlite3_close(h) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK { Issue.record("SQL: \(String(cString: err!))") }
    }

    static var now: Int64 { Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) }

    func change(_ s: Setup, _ args: [String: String]) async -> ToolResult {
        await s.tools["messages_change"]!.handler(.object(args.mapValues(JSONValue.string)))
    }

    func send(_ s: Setup, _ args: [String: String], people: [String]? = nil) async -> ToolResult {
        var a = args.mapValues(JSONValue.string)
        if let people { a["people"] = .array(people.map(JSONValue.string)) }
        return await s.tools["messages_send"]!.handler(.object(a))
    }

    @Test func declaresItsHints() throws {
        let tool = try #require(try setup().tools["messages_change"]).tool
        #expect(tool.annotations?.readOnlyHint == false)
        #expect(tool.annotations?.destructiveHint == true)
    }

    @Test func reactsAndSaysSoOnceRecorded() async throws {
        let s = try setup()
        let db = s.db
        s.ui.effect = { _ in
            Self.exec(
                db,
                "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type, associated_message_guid) VALUES (900, 'R-1', 'Liked', 0, \(Self.now), 1, 2001, 'p:0/M-20'); INSERT INTO chat_message_join VALUES (4, 900, \(Self.now));"
            )
        }
        let r = await change(s, ["action": "react", "message": "M-20", "reaction": "like"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(s.ui.calls == ["tapback(Latchkey.Tapback.like) M-20 «Lunch at 1?» theirs 0"])
        #expect(r.content.jsonText.contains("Put a like tapback"))
        #expect(r.activity != nil)
    }

    @Test func aTapbackAlreadyThereIsNotPressedAgain() async throws {
        let s = try setup()
        let r = await change(s, ["action": "react", "message": "M-20", "reaction": "laugh"])
        #expect(!r.isError)
        #expect(r.content.jsonText.contains("already"))
        #expect(s.ui.calls.isEmpty, "pressing it again would take it back")
    }

    @Test func takesBackOnlyTheOwnersTapback() async throws {
        let s = try setup()
        let db = s.db
        s.ui.effect = { _ in
            Self.exec(
                db,
                "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type, associated_message_guid) VALUES (901, 'R-2', 'Removed', 0, \(Self.now), 1, 3003, 'p:0/M-20'); INSERT INTO chat_message_join VALUES (4, 901, \(Self.now));"
            )
        }
        let r = await change(s, ["action": "unreact", "message": "M-20"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(s.ui.calls.first?.hasPrefix("tapback(Latchkey.Tapback.laugh) M-20") == true, "the laugh, pressed again")
        let none = await change(s, ["action": "unreact", "message": "M-21"])
        #expect(none.isError, "M-21 has tapbacks only from others")
        #expect(s.ui.calls.count == 1)
    }

    @Test func editsAndUnsendsOnlyRecentOwnIMessages() async throws {
        let s = try setup()
        let others = await change(s, ["action": "edit", "message": "M-20", "text": "x"])
        #expect(others.isError && others.content.jsonText.contains("your own"))
        let old = await change(s, ["action": "edit", "message": "M-21", "text": "x"])
        #expect(old.isError && old.content.jsonText.contains("15 minutes"))
        let oldUnsend = await change(s, ["action": "unsend", "message": "M-21"])
        #expect(oldUnsend.isError && oldUnsend.content.jsonText.contains("2 minutes"))
        let sms = await change(s, ["action": "edit", "message": "M-7", "text": "x"])
        #expect(sms.isError)
        #expect(s.ui.calls.isEmpty)
    }

    @Test func editsAFreshMessage() async throws {
        let s = try setup()
        let db = s.db
        Self.exec(
            db,
            "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent) VALUES (910, 'M-NEW', 'See you at 8', 0, \(Self.now), 1, 1); INSERT INTO chat_message_join VALUES (4, 910, \(Self.now));"
        )
        s.ui.effect = { _ in
            Self.exec(db, "UPDATE message SET text = 'See you at 9', date_edited = \(Self.now) WHERE ROWID = 910")
        }
        let r = await change(s, ["action": "edit", "message": "M-NEW", "text": "See you at 9"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(s.ui.calls == ["edit(\"See you at 9\") M-NEW «See you at 8» mine 0"])
        #expect(r.content.jsonText.contains("Changed «See you at 8» to «See you at 9»"))
    }

    @Test func unsendsAFreshMessage() async throws {
        let s = try setup()
        let db = s.db
        Self.exec(
            db,
            "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent) VALUES (911, 'M-OOPS', 'Wrong chat', 0, \(Self.now), 1, 1); INSERT INTO chat_message_join VALUES (4, 911, \(Self.now));"
        )
        let unsent = try PropertyListSerialization.data(
            fromPropertyList: ["rp": [0]], format: .binary, options: 0)
        let hex = unsent.map { String(format: "%02x", $0) }.joined()
        s.ui.effect = { _ in
            Self.exec(
                db,
                "UPDATE message SET text = NULL, date_edited = \(Self.now), message_summary_info = x'\(hex)' WHERE ROWID = 911"
            )
        }
        let r = await change(s, ["action": "unsend", "message": "M-OOPS"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("Unsent «Wrong chat»"))
    }

    @Test func deletesAMessageAndAConversation() async throws {
        let s = try setup()
        let db = s.db
        s.ui.effect = { call in
            if call.hasPrefix("delete M-26") { Self.exec(db, "DELETE FROM chat_message_join WHERE message_id = 26") }
            if call.hasPrefix("delete conversation") {
                Self.exec(db, "DELETE FROM chat_message_join WHERE chat_id = 4")
            }
        }
        let one = await change(s, ["action": "delete", "message": "M-26"])
        #expect(!one.isError, "\(one.content.jsonText)")
        #expect(one.content.jsonText.contains("Recently Deleted"))
        let all = await change(s, ["action": "delete_conversation", "conversation": "iMessage;-;+15557770000"])
        #expect(!all.isError, "\(all.content.jsonText)")
        #expect(
            s.ui.calls.last == "delete conversation iMessage;-;+15557770000 of M-27",
            "the conversation to check the window against, shown by its newest message")
        #expect(all.content.jsonText.contains("Deleted the conversation"))
    }

    @Test func saysPlainlyWhenTheWindowCantBeUsed() async throws {
        let s = try setup()
        s.ui.reason = "The Mac is locked."
        let r = await change(s, ["action": "delete", "message": "M-26"])
        #expect(r.isError)
        #expect(r.content.jsonText.contains("Nothing was changed. The Mac is locked."))
        let reply = await send(s, ["reply_to": "M-26", "text": "ok"])
        #expect(reply.isError && reply.content.jsonText.contains("send to conversation iMessage;-;+15557770000"))
        #expect(s.ui.calls.isEmpty)
    }

    /// Security review 2026-11-05: the window is told which conversation to check before acting.
    @Test func eachChangeNamesItsConversation() async throws {
        let s = try setup()
        _ = await change(s, ["action": "delete", "message": "M-26"])
        let t = try #require(s.ui.targets.first)
        #expect(t.conversation.id == "iMessage;-;+15557770000")
        #expect(t.conversation.participants.map(\.handle) == ["+15557770000"])
        #expect(t.conversation.name == nil)
    }

    /// The window shows no ids: a message with a later twin on the same side is refused.
    @Test func refusesAMessageThatCantBeToldApart() async throws {
        let s = try setup()
        Self.exec(
            s.db,
            """
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent) VALUES (940, 'M-T1', 'ok', 0, \(Self.now - 1000), 1, 1);
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent) VALUES (941, 'M-T2', 'ok', 0, \(Self.now), 1, 1);
            INSERT INTO chat_message_join VALUES (4, 940, \(Self.now - 1000)), (4, 941, \(Self.now));
            """)
        let r = await change(s, ["action": "delete", "message": "M-T1"])
        #expect(r.isError && r.content.jsonText.contains("can't tell which one"))
        let reply = await send(s, ["reply_to": "M-T1", "text": "x"])
        #expect(reply.isError)
        #expect(s.ui.calls.isEmpty)
    }

    @Test func unknownMessagesAreRefused() async throws {
        let s = try setup()
        let r = await change(s, ["action": "delete", "message": "M-NOPE"])
        #expect(r.isError && r.content.jsonText.contains("no message with id M-NOPE"))
    }

    /// FR-173: an inline reply.
    @Test func repliesToAMessage() async throws {
        let s = try setup()
        let db = s.db
        s.ui.effect = { _ in
            Self.exec(
                db,
                "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent, thread_originator_guid) VALUES (920, 'M-RE', 'Noon works', 0, \(Self.now), 1, 1, 'M-20'); INSERT INTO chat_message_join VALUES (4, 920, \(Self.now));"
            )
        }
        let r = await send(s, ["reply_to": "M-20", "text": "Noon works"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(s.ui.calls == ["reply(\"Noon works\") M-20 «Lunch at 1?» theirs 0"])
        #expect(r.content.jsonText.contains("Replied to «Lunch at 1?»"))
    }

    /// FR-172: a new, named group.
    @Test func startsANamedGroup() async throws {
        let s = try setup()
        let db = s.db
        s.ui.effect = { call in
            if call.hasPrefix("group") {
                Self.exec(
                    db,
                    """
                    INSERT INTO chat VALUES (5,'any;+;newgroup','newgroup','','iMessage',43);
                    INSERT INTO chat_handle_join VALUES (5,1),(5,2);
                    INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent) VALUES (930, 'M-G', 'Hi all', 0, \(Self.now), 1, 1);
                    INSERT INTO chat_message_join VALUES (5, 930, \(Self.now));
                    """)
            }
            if call.hasPrefix("name") { Self.exec(db, "UPDATE chat SET display_name = 'Trip' WHERE ROWID = 5") }
        }
        let r = await send(s, ["text": "Hi all", "name": "Trip"], people: ["Sarah", "bob@example.com"])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(s.ui.calls == ["group +15551234567,bob@example.com «Hi all»", "name any;+;newgroup M-G «Trip»"])
        #expect(r.content.jsonText.contains("Started a group with Sarah Lee, Bob Stone (bob@example.com)"))
        #expect(r.content.jsonText.contains("Named it «Trip»"))
        let one = await send(s, ["text": "Hi"], people: ["Sarah"])
        #expect(one.isError, "a group needs two")
    }
}

/// The window checks it shows the asked-for conversation, and acts only on a single match.
@Suite struct MessagesWindowMatchTests {
    static let toni = ConversationIdentity(
        id: "any;+;g", name: nil,
        participants: [
            .init(handle: "toni@example.com", name: "Toni M"), .init(handle: "+14155550100", name: "Toni M"),
        ])
    static let bob = ConversationIdentity(
        id: "any;-;+15550001111", name: nil, participants: [.init(handle: "+15550001111", name: nil)])

    @Test func titleMustNameEveryPersonAndNoOneElse() {
        #expect(MessagesAX.titleNames("Toni M & Toni M", Self.toni))
        #expect(!MessagesAX.titleNames("Toni M", Self.toni), "a person missing")
        #expect(!MessagesAX.titleNames("Toni M & Sarah", Self.toni))
        #expect(!MessagesAX.titleNames("2 People", Self.toni))
        #expect(MessagesAX.titleNames("+1 (555) 000-1111", Self.bob), "a number written Messages' way")
        #expect(!MessagesAX.titleNames("+1 (555) 000-2222", Self.bob))
        #expect(!MessagesAX.titleNames("", Self.bob))
        let named = ConversationIdentity(id: "x", name: "Trip", participants: Self.toni.participants)
        #expect(MessagesAX.titleNames("Trip", named))
        #expect(!MessagesAX.titleNames("Toni M & Toni M", named), "a named group shows its name")
    }

    @Test func rowMustNameTheConversation() {
        #expect(MessagesAX.rowNames("Toni M & Toni M, Latchkey check, Yesterday", Self.toni))
        #expect(MessagesAX.rowNames("+1 (555) 000-1111, Unread, hi, 12:00", Self.bob))
        #expect(!MessagesAX.rowNames("Sarah, Toni M & Toni M, 12:00", Self.toni))
        #expect(!MessagesAX.rowNames("Bat WC Meg, Website, Monday", Self.bob))
    }

    @Test func actsOnlyOnASingleMatch() {
        let target = BalloonTarget(message: "M", text: "Hi", fromMe: true, conversation: Self.bob)
        let mine = MessagesAX.Shown(text: "Hi", description: "", fromMe: true)
        let theirs = MessagesAX.Shown(text: "Hi", description: "", fromMe: false)
        #expect(MessagesAX.pick(target, in: [theirs, mine]) == 1)
        #expect(MessagesAX.pick(target, in: [mine, theirs, mine]) == nil, "two the same: refused")
        #expect(MessagesAX.pick(target, in: [theirs]) == nil)
        var later = target
        later.laterSame = 1
        #expect(MessagesAX.pick(later, in: [mine]) == nil)
        let file = BalloonTarget(
            message: "F", text: "", attachmentNames: ["a.pdf"], fromMe: false, conversation: Self.bob)
        #expect(
            MessagesAX.pick(file, in: [MessagesAX.Shown(text: "x", description: "Bob, a.pdf, PDF", fromMe: false)]) == 0
        )
    }
}
