import Foundation
import Testing

@testable import Latchkey

/// Notes' refusals for notes it can't change safely, and Messages' window actions back on
/// (switched off 2026-11-05 after live checks found them broken; on again 2026-11-07 once each
/// passed on the real Mac).
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

    /// Only plain sending: Messages' window actions were withdrawn (Toni, 2026-11-07).
    @Test func messagesOffersOnlyPlainSending() async throws {
        let db = try MessagesFixture.make()
        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let fake = FakeScripts()
        let tools = MessagesCapability.writeTools(
            store: { store }, contacts: MessagesFixture.FakeContacts(), scripts: fake,
            staging: FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)"))
        #expect(tools.map(\.tool.name) == ["messages_send"])
        let send = try #require(tools.first)
        for key in ["people", "name", "reply_to"] {
            #expect(!send.tool.inputSchema.jsonText.contains("\"\(key)\""), "\(key)")
        }
        #expect(fake.calls.isEmpty, "nothing reached Messages")
    }
}
