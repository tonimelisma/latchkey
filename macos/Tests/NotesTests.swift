import Foundation
import Testing

@testable import Latchkey

@Suite struct NoteBodyTests {
    @Test func decodesStylesChecklistsAndAttachments() throws {
        let data = NotesFixture.body(
            "Title\nHead\nItem\nTodo\nDone\n\u{FFFC}\nPlain",
            runs: [
                .init(length: 6, style: 0), .init(length: 5, style: 1), .init(length: 5, style: 100),
                .init(length: 5, style: 103, done: false), .init(length: 5, style: 103, done: true),
                .init(length: 1, attachment: ("A-1", "public.jpeg")), .init(length: 6),
            ])
        let body = try NoteBody.decode(data)
        #expect(
            body.markdown == """
                # Title
                ## Head
                - Item
                - [ ] Todo
                - [x] Done
                [image A-1]
                Plain
                """)
        #expect(body.attachments == [NoteBody.Attachment(id: "A-1", uti: "public.jpeg")])
        #expect(body.plainText.contains("Todo"))
    }

    @Test func indentsNestedLists() throws {
        let data = NotesFixture.body(
            "A\nB", runs: [.init(length: 2, style: 100), .init(length: 1, style: 100, indent: 1)])
        #expect(try NoteBody.decode(data).markdown == "- A\n  - B")
    }

    @Test func countsLengthsInUTF16LikeNotes() throws {
        // Notes measures runs in UTF-16 units: an emoji counts as 2.
        let data = NotesFixture.body("Hi 👋\nNext", runs: [.init(length: 6, style: 0), .init(length: 4)])
        #expect(try NoteBody.decode(data).markdown == "# Hi 👋\nNext")
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try NoteBody.decode(Data([1, 2, 3])) }
    }
}

@Suite struct NotesStoreTests {
    func store() throws -> NotesStore { try NotesStore(url: NotesFixture.make()) }

    @Test func listsFoldersWithoutTrash() throws {
        let folders = try store().folders()
        #expect(folders.map(\.name) == ["Notes", "Trips"])
        #expect(folders.first?.noteCount == 3)
    }

    @Test func searchesTitlesAndText() throws {
        let s = try store()
        let hits = try s.search("flights", folder: nil, limit: 10)
        #expect(hits.map(\.id) == ["N-LISBON"])
        #expect(hits.first?.snippet.contains("Flights booked") == true)
        #expect(
            try s.search("bread", folder: nil, limit: 10).map(\.id) == ["N-GROCERIES"], "body text, not just the title")
        #expect(try s.search("gone", folder: nil, limit: 10).isEmpty, "Recently Deleted is excluded")
        #expect(try s.search("flights", folder: "Notes", limit: 10).isEmpty, "folder filter")
    }

    @Test func emptyQueryListsRecentNotes() throws {
        let hits = try store().search("", folder: nil, limit: 10)
        #expect(hits.map(\.id) == ["N-GROCERIES", "N-SECRET", "N-LISBON", "N-IDEAS"], "newest first")
    }

    @Test func readsANote() throws {
        let note = try store().read(id: "N-GROCERIES")
        #expect(note.title == "Groceries")
        #expect(note.folder == "Notes")
        #expect(note.text == "# Groceries\n- [x] Milk\n- [ ] Bread\nShop on Saturday")
        #expect(note.modified == NotesFixture.modified)
        #expect(!note.locked)
    }

    @Test func lockedNotesStayClosed() throws {
        let note = try store().read(id: "N-SECRET")
        #expect(note.locked)
        #expect(note.text.isEmpty, "FR-105")
    }

    @Test func findsAnAttachedImage() throws {
        let s = try store()
        let note = try s.read(id: "N-LISBON")
        #expect(note.attachments.map(\.id) == ["A-PHOTO"], "the tag isn't an attachment to Claude")
        #expect(note.text.hasSuffix("Hotel near Alfama #travel"))
        #expect(note.hasInlineItems)
        let image = try s.image(note: "N-LISBON", attachment: "A-PHOTO")
        #expect(image.mimeType == "image/png")
        #expect(!image.data.isEmpty)
    }

    @Test func unknownNoteIsAnError() throws {
        #expect(throws: NotesStore.Failure.self) { try store().read(id: "N-NOPE") }
    }
}

@Suite struct NotesToolTests {
    @Test func toolsDeclareTheirHints() {
        for tool in NotesCapability.readOperations(store: { nil }).map(\.tool) {
            #expect(tool.annotations?.readOnlyHint == true, "\(tool.name)")
            #expect(tool.annotations?.destructiveHint == false)
        }
    }

    @Test func searchToolAnswersWithStructuredResults() async throws {
        let s = try NotesStore(url: NotesFixture.make())
        let tools = NotesCapability.readOperations(store: { s })
        let search = try #require(tools.first { $0.tool.name == "notes_search" })
        let result = await search.handler(.object(["query": .string("lisbon")]))
        #expect(!result.isError)
        #expect(result.structuredContent?["notes"] != nil)
        #expect(result.content.jsonText.contains("Lisbon trip"))
    }

    @Test func missingFullDiskAccessIsExplained() async {
        let tools = NotesCapability.readOperations(store: { nil })
        let result = await tools[0].handler(.object([:]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("Full Disk Access"))
    }
}
