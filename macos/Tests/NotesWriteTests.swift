import Foundation
import Testing

@testable import Latchkey

/// Stands in for osascript: records every script and answers like Notes would.
final class FakeScripts: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(script: String, args: [String])] = []
    var answer: @Sendable (String, [String]) throws -> String = { _, _ in "" }

    func run(_ script: String, _ args: [String]) async throws -> String {
        lock.withLock { calls.append((script, args)) }
        return try answer(script, args)
    }

    var lastArgs: [String] { lock.withLock { calls.last?.args ?? [] } }
}

@Suite struct NoteHTMLTests {
    @Test func convertsMarkdownLikeText() {
        let html = NoteHTML.from(
            """
            # Trip
            Plain & <simple>
            - one
            - two
            1. first
            - [ ] buy
            - [x] done

            End
            """)
        #expect(
            html
                == "<div><h1>Trip</h1></div><div>Plain &amp; &lt;simple&gt;</div><ul><li>one</li><li>two</li></ul>"
                + "<ol><li>first</li></ol><ul><li>☐ buy</li><li>☑ done</li></ul><div><br></div><div>End</div>")
    }

    @Test func nestsIndentedItems() {
        #expect(NoteHTML.from("- a\n  - b") == "<ul><li>a</li><ul><li>b</li></ul></ul>")
    }
}

@Suite struct NotesWriteToolTests {
    func setup() throws -> (NotesStore, FakeScripts, [String: ToolEntry]) {
        let store = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        let tools = NotesCapability.writeTools(store: { store }, scripts: fake)
        return (store, fake, Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) }))
    }

    @Test func toolsDeclareTheirHints() throws {
        let (_, _, tools) = try setup()
        #expect(Set(tools.keys) == ["notes_create", "notes_update", "notes_delete"])
        #expect(tools["notes_create"]?.tool.annotations?.destructiveHint == false)
        #expect(tools["notes_update"]?.tool.annotations?.destructiveHint == true)
        #expect(tools["notes_delete"]?.tool.annotations?.destructiveHint == true)
        for t in tools.values { #expect(t.tool.annotations?.readOnlyHint == false) }
    }

    @Test func createsANoteAndReturnsItsID() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in "x-coredata://STORE-UUID/ICNote/p14" }  // a row the database already has
        let result = await tools["notes_create"]!.handler(
            .object(["title": .string("Ideas"), "text": .string("- [ ] soil"), "folder": .string("notes")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(result.content.jsonText.contains("N-IDEAS"))
        #expect(result.activity == "Claude created the note “Ideas”")
        #expect(fake.lastArgs == ["<div><h1>Ideas</h1></div><ul><li>☐ soil</li></ul>", "Notes"])
    }

    @Test func unknownFolderIsRefusedBeforeNotesIsTouched() async throws {
        let (_, fake, tools) = try setup()
        let result = await tools["notes_create"]!.handler(.object(["title": .string("X"), "folder": .string("Nope")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("Trips"), "lists the folders that exist")
        #expect(fake.calls.isEmpty)
    }

    @Test func appendsToAPlainNote() async throws {
        let (_, fake, tools) = try setup()
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("append"), "text": .string("Plant tulips")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(fake.lastArgs == ["x-coredata://STORE-UUID/ICNote/p14", "<div>Plant tulips</div>"])
        #expect(result.activity == "Claude added to the note “Ideas”")
    }

    @Test func replaceKeepsTheTitle() async throws {
        let (_, fake, tools) = try setup()
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("replace"), "text": .string("New")]))
        #expect(!result.isError)
        #expect(fake.lastArgs.last == "<div><h1>Ideas</h1></div><div>New</div>")
    }

    @Test func editsOnePassage() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { script, _ in
            script.contains("return body") ? "<div><h1>Ideas</h1></div><div>Garden &amp; shed</div>" : ""
        }
        let result = await tools["notes_update"]!.handler(
            .object([
                "id": .string("N-IDEAS"), "mode": .string("edit"), "find": .string("Garden & shed"),
                "text": .string("Garden & greenhouse"),
            ]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(fake.lastArgs.last == "<div><h1>Ideas</h1></div><div>Garden &amp; greenhouse</div>")
    }

    @Test func editNeedsExactlyOneMatch() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in "<div>a</div><div>a</div>" }
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("edit"), "find": .string("a"), "text": .string("b")]))
        #expect(result.isError)
        #expect(fake.calls.count == 1, "read the body, changed nothing")
    }

    @Test func refusesChangesThatWouldLoseChecklistsOrImages() async throws {
        let (_, fake, tools) = try setup()
        for id in ["N-GROCERIES", "N-LISBON", "N-SECRET"] {
            let result = await tools["notes_update"]!.handler(
                .object(["id": .string(id), "mode": .string("append"), "text": .string("eggs")]))
            #expect(result.isError, "\(id)")
            #expect(result.content.jsonText.contains("new note"), "suggests a way forward")
        }
        #expect(fake.calls.isEmpty, "FR-106: Notes was never asked")
    }

    @Test func deletesToRecentlyDeleted() async throws {
        let (_, fake, tools) = try setup()
        let result = await tools["notes_delete"]!.handler(.object(["id": .string("N-GROCERIES")]))
        #expect(!result.isError)
        #expect(fake.lastArgs == ["x-coredata://STORE-UUID/ICNote/p10"])
        #expect(result.content.jsonText.contains("Recently Deleted"))
        #expect(result.activity == "Claude deleted the note “Groceries”")
    }

    @Test func missingAutomationPermissionIsExplained() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in throw ScriptError.notAllowed }
        let result = await tools["notes_delete"]!.handler(.object(["id": .string("N-IDEAS")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("Automation"))
    }
}

@Suite struct NotesFallbackTests {
    /// A database layout Latchkey doesn't know: reading goes through Notes.
    let unknown: NotesCapability.StoreSource = { throw NotesStore.Failure.unknownLayout("test") }

    @Test func readsThroughNotes() async throws {
        let fake = FakeScripts()
        fake.answer = { script, _ in
            if script.contains("count of notes") { return "Notes\t4\nTrips\t1\n" }
            return "Groceries\tNotes\t2026-10-22T09:30:00\tfalse\nMilk\nBread"
        }
        let tools = Dictionary(
            uniqueKeysWithValues: NotesCapability.readTools(store: unknown, scripts: fake).map { ($0.tool.name, $0) })
        let folders = await tools["notes_folders"]!.handler(.object([:]))
        #expect(folders.content.jsonText.contains("Trips: 1 notes"))
        let note = await tools["notes_read"]!.handler(.object(["id": .string("x-coredata://S/ICNote/p1")]))
        #expect(!note.isError)
        #expect(note.content.jsonText.contains("Milk"))
    }

    @Test func refusesChangesItCannotCheck() async throws {
        let fake = FakeScripts()
        fake.answer = { _, _ in "Ideas\tNotes\t2026-10-22T09:30:00\tfalse\nText" }
        let tools = NotesCapability.writeTools(store: unknown, scripts: fake)
        let update = tools.first { $0.tool.name == "notes_update" }!
        let result = await update.handler(
            .object(["id": .string("x-coredata://S/ICNote/p1"), "mode": .string("append"), "text": .string("x")]))
        #expect(result.isError)
        #expect(fake.calls.count == 1, "read only")
    }
}

@Suite struct ScriptRunnerTests {
    @Test func passesArgumentsWithoutInterpretingThem() async throws {
        let out = try await OSAScriptRunner().run(
            "on run argv\nreturn item 1 of argv & \"|\" & item 2 of argv\nend run", ["a \" & quit", "β"])
        #expect(out == "a \" & quit|β")
    }

    @Test func endsAScriptPastItsDeadline() async throws {
        let runner = OSAScriptRunner(timeout: .milliseconds(500))
        await #expect(throws: ScriptError.timedOut) { try await runner.run("delay 5", []) }
    }
}
