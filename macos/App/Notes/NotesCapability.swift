import Foundation

/// Apple Notes (spec 002 US1). Reading comes from Notes' database (plan D2); changes go through
/// Notes with AppleScript (plan D3).
enum NotesCapability {
    /// Opens the store on first use; nil while Latchkey lacks Full Disk Access.
    typealias StoreSource = @Sendable () throws -> NotesStore?

    static func make() -> Capability {
        let source = Opener()
        return Capability(
            id: CapabilityRegistry.notes, title: "Notes", summary: "Read, search, create, edit, and delete notes",
            readTools: readTools(store: { try source.store() }, scripts: OSAScriptRunner()),
            writeTools: writeTools(store: { try source.store() }, scripts: OSAScriptRunner()))
    }

    static let noAccess = """
        Latchkey can't read Notes yet: macOS needs the Mac's owner to turn on Latchkey in \
        System Settings → Privacy & Security → Full Disk Access.
        """

    /// FR-151: results stay well within Claude's limit.

    /// `scripts`, when given, reads through Notes if the database layout is unknown (plan D2).
    static func readOperations(store: @escaping StoreSource, scripts: (any ScriptRunner)? = nil) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "notes_search", title: "Search Notes",
                    description:
                        "Finds notes whose title or text contains the query, newest first. With an empty query, lists the most recently changed notes. Returns each note's id for notes_read.",
                    input: [
                        "query": .stringParam("Words to look for; empty lists recent notes"),
                        "folder": .stringParam("Only notes in this folder (name from notes_folders)"),
                        "limit": .integerParam("At most this many notes (default 20, up to 100)"),
                    ], readOnly: true, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        let limit = min(max(try args.integer("limit", in: 0...Int.max) ?? 20, 1), 100)
                        let hits = try await s.search(
                            args["query"]?.stringValue ?? "", folder: args["folder"]?.stringValue, limit: limit)
                        let text =
                            hits.isEmpty
                            ? "No notes found."
                            : hits.map { h in
                                "- \(h.title) (id \(h.id); \(h.folder); changed \(h.modified.formatted(.iso8601)))"
                                    + (h.locked ? " [locked]" : "") + (h.snippet.isEmpty ? "" : "\n  \(h.snippet)")
                            }.joined(separator: "\n")
                        return .data(.object(["notes": .array(hits.map(json))]), text: text)
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_folders", title: "List Note Folders",
                    description: "Lists the Notes folders and how many notes each holds.",
                    readOnly: true),
                handler: { _ in
                    await run(store, scripts) { s in
                        let folders = try await s.folders()
                        let text = folders.map { "- \($0.name): \($0.noteCount) notes" }.joined(separator: "\n")
                        return .data(
                            .object([
                                "folders": .array(
                                    folders.map {
                                        .object([
                                            "id": .string($0.id), "name": .string($0.name),
                                            "noteCount": .number(Double($0.noteCount)),
                                        ])
                                    })
                            ]), text: text.isEmpty ? "No folders." : text)
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_read", title: "Read a Note",
                    description:
                        "Reads one note: title, folder, dates, and text as Markdown (checklists as - [ ] and - [x]). Attached images appear as [image <id>]; view them with notes_image. Long notes come in parts; pass offset to read on.",
                    input: [
                        "id": .stringParam("The note's id, from notes_search"),
                        "offset": .integerParam("Start at this character, from a previous answer"),
                    ], required: ["id"], readOnly: true),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue else {
                            return .text("Give the note's id.", isError: true)
                        }
                        let n = try await s.read(id: id)
                        let (text, next) = ResultLimit.page(
                            n.text, offset: try args.integer("offset", in: 0...Int.max) ?? 0)
                        let shortened = next != nil
                        var header =
                            "\(n.title) (id \(n.id); folder \(n.folder); changed \(n.modified.formatted(.iso8601)))"
                        if n.locked { header += "\nThis note is locked with a password; its content can't be read." }
                        if let next {
                            header += "\nThe note has \(n.text.count) characters; read on with offset \(next)."
                        }
                        var value = json(n)
                        if case .object(var o) = value {
                            o["text"] = .string(text)
                            o["shortened"] = .bool(shortened)
                            value = .object(o)
                        }
                        return .data(value, text: header + (text.isEmpty ? "" : "\n\n" + text))
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_image", title: "View a Note's Image",
                    description: "Shows an image attached to a note. Large photos are scaled down.",
                    input: [
                        "note": .stringParam("The note's id"),
                        "attachment": .stringParam("The image's id, from [image <id>] in notes_read"),
                    ], required: ["note", "attachment"], readOnly: true),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let note = args["note"]?.stringValue, let attachment = args["attachment"]?.stringValue
                        else {
                            return .text("Give the note's id and the image's id.", isError: true)
                        }
                        let image = try await s.image(note: note, attachment: attachment)
                        return .image(image.data, mimeType: image.mimeType)
                    }
                }),
        ]
    }

    // MARK: helpers

    private static func run(
        _ source: StoreSource, _ scripts: (any ScriptRunner)?, _ body: (any NotesReader) async throws -> ToolResult
    ) async -> ToolResult {
        do {
            let reader: any NotesReader
            do {
                guard let store = try source() else { return .text(noAccess, isError: true) }
                reader = store
            } catch NotesStore.Failure.unknownLayout(_) where scripts != nil {
                reader = NotesScriptReader(scripts: scripts!)
            }
            return try await body(reader)
        } catch let failure as NotesStore.Failure {
            return .text(explain(failure), isError: true)
        } catch let failure as ScriptError {
            return .text(explain(failure), isError: true)
        } catch let a as ArgumentError {
            return .text(a.message, isError: true)
        } catch {
            return .text("Notes couldn't be read: \(error.localizedDescription)", isError: true)
        }
    }

    static func explain(_ f: ScriptError) -> String {
        switch f {
        case .notAllowed:
            "Latchkey isn't allowed to control Notes. The Mac's owner can allow it in System Settings → Privacy & Security → Automation → Latchkey."
        case .timedOut:
            "Notes didn't answer within 25 seconds. The change may or may not have happened; check with notes_read."
        case .failed(let message): "Notes reported an error: \(message)"
        }
    }

    static func explain(_ f: NotesStore.Failure) -> String {
        switch f {
        case .cannotOpen: noAccess
        case .unknownLayout(let why): "This version of Notes stores notes in a way Latchkey doesn't know yet (\(why))."
        case .noSuchNote(let id): "There is no note with id \(id). Search again with notes_find."
        case .noSuchAttachment(let id): "That note has no attachment with id \(id)."
        case .notAnImage(let id): "The attachment \(id) isn't an image Latchkey can show."
        }
    }

    private static func json(_ s: NotesStore.Summary) -> JSONValue {
        .object([
            "id": .string(s.id), "title": .string(s.title), "folder": .string(s.folder),
            "modified": .string(s.modified.formatted(.iso8601)), "snippet": .string(s.snippet),
            "locked": .bool(s.locked),
        ])
    }

    private static func json(_ n: NotesStore.Note) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(n.id), "title": .string(n.title), "folder": .string(n.folder),
            "modified": .string(n.modified.formatted(.iso8601)), "locked": .bool(n.locked), "text": .string(n.text),
            "attachments": .array(
                n.attachments.map {
                    .object(["id": .string($0.id), "type": .string($0.uti), "image": .bool($0.isImage)])
                }),
        ]
        if let c = n.created { o["created"] = .string(c.formatted(.iso8601)) }
        return .object(o)
    }

    // MARK: changing notes (plan D3)

    static func writeOperations(store: @escaping StoreSource, scripts: any ScriptRunner) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "notes_create", title: "Create a Note",
                    description:
                        "Creates a note in Notes on the Mac. The text is Markdown-like: # headings, - lists, 1. numbered lists; - [ ] items become ☐ (Notes doesn't let other apps make real checklists).",
                    input: [
                        "title": .stringParam("The note's title"),
                        "text": .stringParam("The note's text, below the title"),
                        "folder": .stringParam("Folder name from notes_folders; the default folder if left out"),
                    ], required: ["title"], readOnly: false, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let title = args["title"]?.stringValue, !title.isEmpty else {
                            return .text("Give the note a title.", isError: true)
                        }
                        var folder = ""
                        if let wanted = args["folder"]?.stringValue, !wanted.isEmpty {
                            let folders = try await s.folders()
                            guard
                                let match = folders.first(where: {
                                    $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                                })
                            else {
                                return .text(
                                    "There is no folder named \(wanted). The folders are: "
                                        + folders.map(\.name).joined(separator: ", ") + ".", isError: true)
                            }
                            folder = match.name
                        }
                        let text = args["text"]?.stringValue ?? ""
                        let html = NoteHTML.title(title) + (text.isEmpty ? "" : NoteHTML.from(text))
                        let scriptID = try await scripts.run(Script.create, [html, folder])
                        var id: String?
                        for _ in 0..<15 {  // Notes writes its database a moment later
                            id = try await s.identifier(forScriptID: scriptID)
                            if id != nil { break }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        var result = ToolResult.data(
                            .object(["id": id.map(JSONValue.string) ?? .null, "title": .string(title)]),
                            text: id.map { "Created “\(title)” (id \($0))." }
                                ?? "Created “\(title)”. It will show up in notes_find in a moment.")
                        result.activity = "Claude created the note “\(title)”"
                        result.made = "the note “\(title)”" + (folder.isEmpty ? "" : " in \(folder)")
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_update", title: "Change a Note",
                    description:
                        "Changes a note's text. mode append adds text at the end; replace sets everything below the title; edit replaces the passage given in find (it must appear exactly once in one paragraph). Text is Markdown-like as in notes_create. Notes with checklists, images, or tables can't be changed this way without losing them, so Latchkey refuses those.",
                    input: [
                        "id": .stringParam("The note's id, from notes_search"),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array(["append", "replace", "edit"].map(JSONValue.string)),
                            "description": .string("append, replace, or edit"),
                        ]),
                        "text": .stringParam("The text to add, the new text, or the passage's replacement"),
                        "find": .stringParam("For edit: the exact passage to replace"),
                    ], required: ["id", "mode", "text"], readOnly: false, destructive: true, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue, let mode = args["mode"]?.stringValue,
                            let text = args["text"]?.stringValue
                        else { return .text("Give the note's id, a mode, and the text.", isError: true) }
                        let note = try await s.read(id: id)
                        guard s.knowsContents else {
                            return .text(
                                "Latchkey can't check this note for checklists or images with this version of Notes, so it doesn't change existing notes. Create a new note instead.",
                                isError: true)
                        }
                        if let why = refusal(note) { return .text(why, isError: true) }
                        switch mode {
                        case "append":
                            _ = try await scripts.run(Script.append, [note.scriptID, NoteHTML.from(text)])
                        case "replace":
                            _ = try await scripts.run(
                                Script.setBody, [note.scriptID, NoteHTML.title(note.title) + NoteHTML.from(text)])
                        case "edit":
                            guard let find = args["find"]?.stringValue, !find.isEmpty else {
                                return .text("For edit, give the passage to replace in find.", isError: true)
                            }
                            let body = try await scripts.run(Script.getBody, [note.scriptID])
                            let needle = NoteHTML.escape(find)
                            let count = body.components(separatedBy: needle).count - 1
                            guard count == 1 else {
                                return .text(
                                    count == 0
                                        ? "The passage wasn't found in “\(note.title)”, or it spans paragraphs or formatting. Read the note again and give a shorter passage."
                                        : "The passage appears \(count) times in “\(note.title)”. Include more of the surrounding text.",
                                    isError: true)
                            }
                            _ = try await scripts.run(
                                Script.setBody,
                                [note.scriptID, body.replacingOccurrences(of: needle, with: NoteHTML.escape(text))])
                        default:
                            return .text("mode must be append, replace, or edit.", isError: true)
                        }
                        var result = ToolResult.text(
                            mode == "append" ? "Added to “\(note.title)”." : "Changed “\(note.title)”.")
                        result.activity =
                            mode == "append"
                            ? "Claude added to the note “\(note.title)”" : "Claude changed the note “\(note.title)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_delete", title: "Delete a Note",
                    description: "Moves a note to Recently Deleted in Notes, where it stays for 30 days.",
                    input: ["id": .stringParam("The note's id, from notes_search")], required: ["id"], readOnly: false,
                    destructive: true, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue else {
                            return .text("Give the note's id.", isError: true)
                        }
                        let note = try await s.read(id: id)
                        _ = try await scripts.run(Script.delete, [note.scriptID])
                        var result = ToolResult.text(
                            "Moved “\(note.title)” to Recently Deleted. Notes keeps it there for 30 days.")
                        result.activity = "Claude deleted the note “\(note.title)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_delete_folder", title: "Delete a Note Folder",
                    description:
                        "Deletes a folder of the default Notes account; its notes move to Recently Deleted for 30 days. Not the account's default folder, nor a folder with folders inside.",
                    input: ["folder": .stringParam("The folder's name, from notes_folders")], required: ["folder"],
                    readOnly: false, destructive: true, deadlineMS: 30_000),
                handler: { args in
                    guard let folder = args["folder"]?.stringValue, !folder.isEmpty else {
                        return .text("Give the folder's name.", isError: true)
                    }
                    do {
                        let count = try await scripts.run(Script.deleteFolder, [folder])
                        let notes = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                        var result = ToolResult.text(
                            notes == 0
                                ? "Deleted the empty folder “\(folder)”."
                                : "Deleted the folder “\(folder)”; its \(notes) note\(notes == 1 ? "" : "s") moved to Recently Deleted, where Notes keeps them for 30 days."
                        )
                        result.activity = "Claude deleted the Notes folder “\(folder)”"
                        return result
                    } catch ScriptError.failed(let message) where message.contains("LATCHKEY_") {
                        let why =
                            message.contains("LATCHKEY_NO_FOLDER")
                            ? "There's no folder named “\(folder)” in the default Notes account."
                            : message.contains("LATCHKEY_DEFAULT_FOLDER")
                                ? "“\(folder)” is the account's default folder, which Latchkey doesn't delete."
                                : "“\(folder)” has folders inside it; delete those first."
                        return .text(why + " Nothing was deleted.", isError: true)
                    } catch let failure as ScriptError {
                        return .text(explain(failure), isError: true)
                    } catch {
                        return .text("Notes couldn't delete the folder: \(error.localizedDescription)", isError: true)
                    }
                }),
        ]
    }

    /// FR-106: why a note can't be changed without losing part of it, or nil.
    static func refusal(_ note: NotesStore.Note) -> String? {
        var parts: [String] = []
        if note.locked { parts.append("it's locked with a password") }
        if note.hasChecklists { parts.append("it has checklists") }
        if note.hasInlineItems { parts.append("it has mentions, tags, or links") }
        if !note.attachments.isEmpty { parts.append("it has images, tables, or other attachments") }
        guard !parts.isEmpty else { return nil }
        return """
            Latchkey didn't change “\(note.title)”: \(parts.joined(separator: " and ")). Notes only lets \
            other apps rewrite a note's whole text, which would lose those. Create a new note instead, \
            or ask the Mac's owner to change this one in Notes.
            """
    }

    /// AppleScript for Notes; the user's text arrives as arguments (argv).
    enum Script {
        static let create = """
            on run argv
            set theBody to item 1 of argv
            set folderName to item 2 of argv
            tell application "Notes"
            if folderName is "" then
            set n to make new note with properties {body:theBody}
            else
            set n to make new note at folder folderName with properties {body:theBody}
            end if
            return id of n
            end tell
            end run
            """
        static let append = """
            on run argv
            set theID to item 1 of argv
            set extra to item 2 of argv
            tell application "Notes"
            set n to note id theID
            set body of n to (body of n) & extra
            end tell
            end run
            """
        static let setBody = """
            on run argv
            set theID to item 1 of argv
            set newBody to item 2 of argv
            tell application "Notes" to set body of note id theID to newBody
            end run
            """
        static let getBody = """
            on run argv
            set theID to item 1 of argv
            tell application "Notes" to return body of note id theID
            end run
            """
        static let delete = """
            on run argv
            set theID to item 1 of argv
            tell application "Notes" to delete note id theID
            end run
            """
        /// argv: folder name. Answers how many notes it held (spec 002 FR-152).
        static let deleteFolder = """
            on run argv
            set folderName to item 1 of argv
            tell application "Notes"
            set acc to default account
            if not (exists folder folderName of acc) then error "LATCHKEY_NO_FOLDER"
            set f to folder folderName of acc
            if (id of f) is (id of (default folder of acc)) then error "LATCHKEY_DEFAULT_FOLDER"
            if (count of folders of f) > 0 then error "LATCHKEY_HAS_FOLDERS"
            set noteCount to count of notes of f
            delete f
            return noteCount as text
            end tell
            end run
            """
    }

    /// Opens the database once, on first use, so a later grant of Full Disk Access takes effect.
    private final class Opener: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: NotesStore?

        func store() throws -> NotesStore? {
            lock.lock()
            defer { lock.unlock() }
            if let opened { return opened }
            guard FileManager.default.fileExists(atPath: Permissions.notesDatabase.path) else {
                throw NotesStore.Failure.unknownLayout("Notes has no database on this Mac yet")
            }
            guard (try? FileHandle(forReadingFrom: Permissions.notesDatabase))?.closeAndReturnTrue() == true else {
                return nil
            }
            opened = try NotesStore(url: Permissions.notesDatabase)
            return opened
        }
    }
}

extension FileHandle {
    fileprivate func closeAndReturnTrue() -> Bool {
        try? close()
        return true
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
}
