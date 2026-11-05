import Foundation
import SQLite3
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
        let tools = NotesCapability.writeOperations(store: { store }, scripts: fake)
        return (store, fake, Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) }))
    }

    @Test func toolsDeclareTheirHints() throws {
        let (_, _, tools) = try setup()
        #expect(
            Set(tools.keys) == [
                "notes_create", "notes_update", "notes_move", "notes_rename", "notes_check", "notes_create_folder",
                "notes_delete", "notes_delete_folder",
            ])
        #expect(tools["notes_move"]?.tool.annotations?.destructiveHint == false)
        #expect(tools["notes_create_folder"]?.tool.annotations?.destructiveHint == false)
        #expect(tools["notes_delete_folder"]?.tool.annotations?.destructiveHint == true)
        #expect(tools["notes_create"]?.tool.annotations?.destructiveHint == false)
        #expect(tools["notes_update"]?.tool.annotations?.destructiveHint == true)
        #expect(tools["notes_delete"]?.tool.annotations?.destructiveHint == true)
        for t in tools.values { #expect(t.tool.annotations?.readOnlyHint == false) }
    }

    /// Spec 002 FR-152: a folder can be deleted; its notes go to Recently Deleted.
    @Test func deletesAFolder() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in "2" }
        let result = await tools["notes_delete_folder"]!.handler(.object(["folder": .string("Latchkey Check")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(result.content.jsonText.contains("2 notes moved to Recently Deleted"))
        #expect(fake.calls.last?.script == NotesCapability.Script.deleteFolder)
        #expect(fake.lastArgs == ["Latchkey Check"])
        #expect(result.activity == "Claude deleted the Notes folder “Latchkey Check”")
    }

    /// 2026-11-02: ten folders answered "deleted" stayed in Notes, because Notes hadn't saved the
    /// deletion. "Deleted" only once Notes' database no longer lists the folder.
    @Test func aFolderStillInNotesDatabaseIsNotSaidDeleted() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in "1" }
        let result = await tools["notes_delete_folder"]!.handler(.object(["folder": .string("Trips")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("hasn't saved that yet"), "\(result.content.jsonText)")
        #expect(fake.calls.last?.script.contains("delete n") == true, "the notes first, then the folder")
    }

    @Test func refusesTheDefaultFolder() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in throw ScriptError.failed("execution error: LATCHKEY_DEFAULT_FOLDER (-2700)") }
        let result = await tools["notes_delete_folder"]!.handler(.object(["folder": .string("Notes")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("default folder"))
        #expect(result.content.jsonText.contains("Nothing was deleted"))
    }

    @Test func theChangeToolReachesFolderDelete() async throws {
        let fake = FakeScripts()
        fake.answer = { _, _ in "0" }
        let store = try NotesStore(url: NotesFixture.make())
        let change = try #require(
            NotesCapability.writeTools(store: { store }, scripts: fake).first { $0.tool.name == "notes_change" })
        let result = await change.handler(.object(["action": .string("delete_folder"), "folder": .string("Old")]))
        #expect(result.content.jsonText.contains("Deleted the empty folder “Old”"), "\(result.content.jsonText)")
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

    /// Spec 002 FR-154 (2026-11-01): a folder that doesn't exist is made, not refused.
    @Test func aNewFolderIsMadeForTheNote() async throws {
        let (_, fake, tools) = try setup()
        let result = await tools["notes_create"]!.handler(.object(["title": .string("X"), "folder": .string("Nope")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(result.content.jsonText.contains("The folder “Nope” was new and has been made"))
        #expect(fake.lastArgs.last == "Nope")
        let existing = await tools["notes_create"]!.handler(
            .object(["title": .string("Y"), "folder": .string("trips")]))
        #expect(!existing.content.jsonText.contains("was new"), "an existing folder, in any case")
        #expect(fake.lastArgs.last == "Trips")
    }

    /// Spec 002 FR-154: move and rename go to Notes with the note's own id.
    @Test func movesAndRenamesANote() async throws {
        let (_, fake, tools) = try setup()
        let moved = await tools["notes_move"]!.handler(.object(["id": .string("N-IDEAS"), "folder": .string("trips")]))
        #expect(!moved.isError, "\(moved.content.jsonText)")
        #expect(fake.lastArgs == ["x-coredata://STORE-UUID/ICNote/p14", "Trips"])
        // The title is the note's first line (seen live: setting only the name left that line).
        fake.answer = { _, _ in "<div><h1>Ideas</h1></div><div>Ideas for the garden</div>" }
        let renamed = await tools["notes_rename"]!.handler(
            .object(["id": .string("N-IDEAS"), "title": .string("Garden & ideas")]))
        #expect(!renamed.isError, "\(renamed.content.jsonText)")
        #expect(
            fake.lastArgs == [
                "x-coredata://STORE-UUID/ICNote/p14",
                "<div><h1>Garden &amp; ideas</h1></div><div>Ideas for the garden</div>",
            ], "only the first line changes")
        fake.answer = { _, _ in "<div><b>Other</b></div><div>Ideas</div>" }
        let notTitle = await tools["notes_rename"]!.handler(
            .object(["id": .string("N-IDEAS"), "title": .string("New")]))
        #expect(notTitle.isError, "the title isn't in the first line as plain text")
        let twoLines = await tools["notes_rename"]!.handler(
            .object(["id": .string("N-IDEAS"), "title": .string("a\nb")]))
        #expect(twoLines.isError)
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

    /// FR-155, FR-158: notes with checklists or images go to Notes' window, never through a
    /// rewrite; without the window nothing changes. A locked note is refused (FR-106).
    @Test func notesThatWouldLoseThingsNeverGetRewritten() async throws {
        let (_, fake, tools) = try setup()
        for id in ["N-GROCERIES", "N-LISBON", "N-SECRET"] {
            let result = await tools["notes_update"]!.handler(
                .object(["id": .string(id), "mode": .string("append"), "text": .string("eggs")]))
            #expect(result.isError, "\(id)")
            #expect(
                result.content.jsonText.contains(id == "N-SECRET" ? "locked" : "Notes' window"),
                "\(result.content.jsonText)")
        }
        #expect(fake.calls.isEmpty, "Notes was never asked to rewrite")
    }

    @Test func deletesToRecentlyDeleted() async throws {
        let url = try NotesFixture.make()
        let store = try NotesStore(url: url)
        let fake = FakeScripts()
        // Notes saves the deletion: the note moves to Recently Deleted (folder 3) in its database.
        fake.answer = { _, _ in
            var db: OpaquePointer?
            sqlite3_open(url.path, &db)
            sqlite3_exec(
                db, "UPDATE ZICCLOUDSYNCINGOBJECT SET ZFOLDER = 3 WHERE ZIDENTIFIER = 'N-GROCERIES'", nil, nil, nil)
            sqlite3_close(db)
            return ""
        }
        let tools = Dictionary(
            uniqueKeysWithValues: NotesCapability.writeOperations(store: { store }, scripts: fake).map {
                ($0.tool.name, $0)
            })
        let result = await tools["notes_delete"]!.handler(.object(["id": .string("N-GROCERIES")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(fake.lastArgs == ["x-coredata://STORE-UUID/ICNote/p10"])
        #expect(result.content.jsonText.contains("Recently Deleted"))
        #expect(result.activity == "Claude deleted the note “Groceries”")
    }

    /// With the Mac locked Notes' scripting dropped a note its database kept (2026-11-04):
    /// "deleted" only once the database agrees.
    @Test func aNoteNotesHasntSavedAsDeletedIsSaidSo() async throws {
        let (_, _, tools) = try setup()
        let result = await tools["notes_delete"]!.handler(.object(["id": .string("N-IDEAS")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("hasn't saved"), "\(result.content.jsonText)")
    }

    @Test func missingAutomationPermissionIsExplained() async throws {
        let (_, fake, tools) = try setup()
        fake.answer = { _, _ in throw ScriptError.notAllowed }
        let result = await tools["notes_delete"]!.handler(.object(["id": .string("N-IDEAS")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("allowed to control Notes"))
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
            uniqueKeysWithValues: NotesCapability.readOperations(store: unknown, scripts: fake).map {
                ($0.tool.name, $0)
            })
        let folders = await tools["notes_folders"]!.handler(.object([:]))
        #expect(folders.content.jsonText.contains("Trips: 1 notes"))
        let note = await tools["notes_read"]!.handler(.object(["id": .string("x-coredata://S/ICNote/p1")]))
        #expect(!note.isError)
        #expect(note.content.jsonText.contains("Milk"))
    }

    @Test func refusesChangesItCannotCheck() async throws {
        let fake = FakeScripts()
        fake.answer = { _, _ in "Ideas\tNotes\t2026-10-22T09:30:00\tfalse\nText" }
        let tools = NotesCapability.writeOperations(store: unknown, scripts: fake)
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

    static let echo = """
        on run argv
        set AppleScript's text item delimiters to linefeed
        return argv as text
        end run
        """

    /// Claude's text reaches osascript as arguments; none may be read as an option such as -e,
    /// which would add AppleScript lines (security scan, 2026-10-24).
    @Test func argumentsThatLookLikeOptionsStayData() async throws {
        let args = ["-e", "do shell script \"echo injected\"", "-l", "JavaScript", "--", "-s", "plain"]
        let out = try await OSAScriptRunner().run(Self.echo, args)
        #expect(out.components(separatedBy: "\n") == args)
        #expect(try await OSAScriptRunner().run(Self.echo, ["-e"]) == "-e")
    }

    @Test func endsAScriptPastItsDeadline() async throws {
        let runner = OSAScriptRunner(timeout: .milliseconds(500))
        await #expect(throws: ScriptError.timedOut) { try await runner.run("delay 5", []) }
    }
}
