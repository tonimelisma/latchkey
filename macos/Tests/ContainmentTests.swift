import Foundation
import Testing

@testable import Latchkey

/// Notes' refusals for notes it can't change safely. Which Messages tools exist, and their input schemas, are
/// pinned in the snapshots in relay/e2e/toolsnaps/mac (spec 016 FR-1604).
@Suite struct ContainmentTests {
    func notes() throws -> (FakeScripts, [String: ToolEntry]) {
        let store = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        let tools = NotesCapability.writeOperations(store: { store }, scripts: fake)
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
        #expect(r.content.jsonText.contains("which Latchkey doesn't use"))
    }

    @Test func plainNotesStillChange() async throws {
        let (fake, tools) = try notes()
        let r = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("append"), "text": .string("Plant tulips")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.calls.count == 1)
    }
}
