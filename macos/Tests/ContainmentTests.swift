import Foundation
import Testing

@testable import Latchkey

/// While Notes' window editing and Messages' window actions are switched off (live checks of
/// 2026-11-05: a checklist note mangled, tapbacks not landing, edits failing), the app refuses
/// plainly and touches nothing.
@Suite struct ContainmentTests {
    func notes() throws -> (FakeScripts, [String: ToolEntry]) {
        let store = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        let tools = NotesCapability.writeOperations(store: { store }, scripts: fake, window: .unavailable)
        return (fake, Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) }))
    }

    @Test func notesWithChecklistsOrImagesAreRefusedAndUntouched() async throws {
        let (fake, tools) = try notes()
        for (id, why) in [("N-GROCERIES", "checklists"), ("N-LISBON", "images")] {
            for mode in ["append", "edit"] {
                let r = await tools["notes_update"]!.handler(
                    .object([
                        "id": .string(id), "mode": .string(mode), "text": .string("x"), "find": .string("Flights"),
                    ]))
                #expect(r.isError, "\(id) \(mode)")
                #expect(r.content.jsonText.contains(why), "\(r.content.jsonText)")
                #expect(r.content.jsonText.contains("Create a new note instead"))
            }
            let renamed = await tools["notes_rename"]!.handler(.object(["id": .string(id), "title": .string("New")]))
            #expect(renamed.isError)
        }
        #expect(fake.calls.isEmpty, "Notes was never asked to change anything")
    }

    @Test func tickingIsRefused() async throws {
        let (fake, tools) = try notes()
        let r = await tools["notes_check"]!.handler(.object(["id": .string("N-GROCERIES"), "find": .string("Bread")]))
        #expect(r.isError)
        #expect(r.content.jsonText.contains("can't tick or untick"))
        #expect(fake.calls.isEmpty)
    }

    @Test func checklistItemsInANewNoteStayBoxesAndSaySo() async throws {
        let (fake, tools) = try notes()
        fake.answer = { _, _ in "x-coredata://STORE-UUID/ICNote/p14" }
        let r = await tools["notes_create"]!.handler(
            .object(["title": .string("Ideas"), "text": .string("- [ ] soil")]))
        #expect(!r.isError, "the note is made")
        #expect(fake.calls.count == 1, "one AppleScript create, no window")
        #expect(r.content.jsonText.contains("☐ and ☑ characters"))
        #expect(r.content.jsonText.contains("aren't available yet"))
    }

    @Test func plainNotesStillChange() async throws {
        let (fake, tools) = try notes()
        let r = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("append"), "text": .string("Plant tulips")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.calls.count == 1)
    }

    @Test func messagesWindowActionsAreGone() async throws {
        let db = try MessagesFixture.make()
        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let fake = FakeScripts()
        let tools = MessagesCapability.writeTools(
            store: { store }, contacts: MessagesFixture.FakeContacts(), scripts: fake,
            staging: FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)"),
            ui: FakeMessagesUI())
        #expect(tools.map(\.tool.name) == ["messages_send"], "no messages_change")
        let send = try #require(tools.first)
        #expect(!send.tool.inputSchema.jsonText.contains("reply_to"))
        for args: [String: JSONValue] in [
            ["people": .array([.string("sarah"), .string("tom")]), "text": .string("hi")],
            ["reply_to": .string("M1"), "text": .string("hi")],
        ] {
            let r = await send.handler(.object(args))
            #expect(r.isError)
            #expect(r.content.jsonText.contains("being fixed"))
        }
        #expect(fake.calls.isEmpty, "nothing reached Messages")
    }
}
