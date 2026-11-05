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
            readTools: readTools(store: { try source.store() }, scripts: OSAScriptRunner(app: Permissions.notesApp)),
            writeTools: writeTools(
                store: { try source.store() }, scripts: OSAScriptRunner(app: Permissions.notesApp), window: .live))
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
                                "- \(h.title) (id \(h.id); \(h.folder.isEmpty ? "no folder" : h.folder); changed \(h.modified.formatted(.iso8601)))"
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
                            "\(n.title) (id \(n.id); \(n.folder.isEmpty ? "no folder" : "folder \(n.folder)"); changed \(n.modified.formatted(.iso8601)))"
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
        } catch let w as WindowFailure {
            return .text(w.message, isError: true)
        } catch {
            // Full Disk Access turned off after the database was opened (FR-625).
            if !Permissions.hasFullDiskAccess { return .text(noAccess, isError: true) }
            return .text("Notes couldn't be read: \(error.localizedDescription)", isError: true)
        }
    }

    static func explain(_ f: ScriptError) -> String {
        switch f {
        case .notAllowed:
            "Latchkey isn't allowed to control Notes. The Mac's owner can allow it in Latchkey's Settings → Permissions."
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

    /// Notes with checklists, links, or images, and checklists Claude writes, go through Notes'
    /// window (plan D3a); `window` stands in for it in tests.
    static func writeOperations(
        store: @escaping StoreSource, scripts: any ScriptRunner, window: NoteWindow = .unavailable
    )
        -> [ToolEntry]
    {
        [
            ToolEntry(
                tool: .make(
                    "notes_create", title: "Create a Note",
                    description:
                        "Creates a note in Notes on the Mac. The text is Markdown-like: # headings, - lists, 1. numbered lists, - [ ] and - [x] checklist items (real Notes checklists).",
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
                        var newFolder = false
                        if let wanted = args["folder"]?.stringValue, !wanted.isEmpty {
                            // A folder that doesn't exist yet is made in the default account.
                            let match = try await s.folders().first {
                                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                            }
                            folder = match?.name ?? wanted
                            newFolder = match == nil
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
                        var made = newFolder ? " The folder “\(folder)” was new and has been made." : ""
                        if hasChecklistItems(text) {
                            // FR-156: written as ☐/☑ lines, made real in Notes' window (FR-158: kept so without it).
                            if let id {
                                do {
                                    let last = lastShownLine(text)
                                    try await inWindow(
                                        scriptID: scriptID, noteID: id, window: window, ready: { $0.contains(last) }
                                    ) { shown in
                                        let ns = shown as NSString
                                        let newline = ns.range(of: "\n")
                                        let start = newline.location == NSNotFound ? ns.length : newline.location + 1
                                        try await makeChecklists(
                                            shown, region: NSRange(location: start, length: ns.length - start),
                                            noteID: id, window: window)
                                    }
                                    made += await savedNote(window) {
                                        (try? await s.read(id: id))?.hasChecklists == true
                                    }
                                } catch let f as WindowFailure {
                                    made += f.boxes
                                }
                            } else {
                                made +=
                                    WindowFailure(
                                        message: "Notes hadn't saved the new note yet to make them real ones."
                                    )
                                    .boxes
                            }
                        }
                        var result = ToolResult.data(
                            .object(["id": id.map(JSONValue.string) ?? .null, "title": .string(title)]),
                            text: (id.map { "Created “\(title)” (id \($0))." }
                                ?? "Created “\(title)”. It will show up in notes_find in a moment.") + made)
                        result.activity = "Claude created the note “\(title)”"
                        result.made = "the note “\(title)”" + (folder.isEmpty ? "" : " in \(folder)")
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_update", title: "Change a Note",
                    description:
                        "Changes a note's text. mode append adds text at the end; replace sets everything below the title; edit replaces the passage given in find (it must appear exactly once). Text is Markdown-like as in notes_create. Notes with checklists, links, or images are changed in Notes' window, in place, keeping them (headings and bullets written there become plain lines).",
                    input: [
                        "id": .stringParam("The note's id, from notes_search"),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array(["append", "replace", "edit"].map(JSONValue.string)),
                            "description": .string("append, replace, or edit"),
                        ]),
                        "text": .stringParam("The text to add, the new text, or the passage's replacement"),
                        "find": .stringParam("For edit: the exact passage to replace"),
                    ], required: ["id", "mode", "text"], readOnly: false, destructive: true, deadlineMS: 60_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue, let mode = args["mode"]?.stringValue,
                            let text = args["text"]?.stringValue
                        else { return .text("Give the note's id, a mode, and the text.", isError: true) }
                        guard ["append", "replace", "edit"].contains(mode) else {
                            return .text("mode must be append, replace, or edit.", isError: true)
                        }
                        let find = args["find"]?.stringValue ?? ""
                        if mode == "edit", find.isEmpty {
                            return .text("For edit, give the passage to replace in find.", isError: true)
                        }
                        let note = try await s.read(id: id)
                        guard s.knowsContents else {
                            return .text(
                                "Latchkey can't check this note for checklists or images with this version of Notes, so it doesn't change existing notes. Create a new note instead.",
                                isError: true)
                        }
                        if let why = refusal(note, replacing: mode == "replace") { return .text(why, isError: true) }
                        var ending = ""
                        if needsWindow(note) {
                            // FR-155: in place, in Notes' window.
                            try await inWindow(scriptID: note.scriptID, noteID: note.id, window: window) { shown in
                                let plan: NoteEditPlan
                                switch mode {
                                case "append": plan = NoteWindowEdit.append(to: shown, NoteWindowEdit.display(text))
                                case "replace":
                                    plan = NoteWindowEdit.replaceBody(of: shown, with: NoteWindowEdit.display(text))
                                default:
                                    switch NoteWindowEdit.edit(shown, find: find, with: text) {
                                    case .success(let p): plan = p
                                    case .failure(let problem): throw WindowFailure(message: passage(problem, note))
                                    }
                                }
                                try await apply(
                                    plan, to: shown, noteID: note.id, window: window, checklists: mode != "edit")
                            }
                            ending = await savedNote(window) { await changed(s, note) }
                        } else {
                            switch mode {
                            case "append":
                                _ = try await scripts.run(Script.append, [note.scriptID, NoteHTML.from(text)])
                            case "replace":
                                _ = try await scripts.run(
                                    Script.setBody, [note.scriptID, NoteHTML.title(note.title) + NoteHTML.from(text)])
                            default:
                                let body = try await scripts.run(Script.getBody, [note.scriptID])
                                let needle = NoteHTML.escape(find)
                                let count = body.components(separatedBy: needle).count - 1
                                guard count == 1 else {
                                    return .text(passage(count == 0 ? .notFound : .several(count), note), isError: true)
                                }
                                _ = try await scripts.run(
                                    Script.setBody,
                                    [note.scriptID, body.replacingOccurrences(of: needle, with: NoteHTML.escape(text))])
                            }
                            if mode != "edit", hasChecklistItems(text) {
                                ending = await realChecklists(
                                    note, written: text, replace: mode == "replace", window, s)
                            }
                        }
                        var result = ToolResult.text(
                            (mode == "append" ? "Added to “\(note.title)”." : "Changed “\(note.title)”.") + ending)
                        result.activity =
                            mode == "append"
                            ? "Claude added to the note “\(note.title)”" : "Claude changed the note “\(note.title)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_move", title: "Move a Note",
                    description: "Moves a note to another folder (made first if it doesn't exist).",
                    input: [
                        "id": .stringParam("The note's id, from notes_find"),
                        "folder": .stringParam("The folder to move it to"),
                    ], required: ["id", "folder"], readOnly: false, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue, let wanted = args["folder"]?.stringValue,
                            !wanted.isEmpty
                        else { return .text("Give the note's id and the folder.", isError: true) }
                        let note = try await s.read(id: id)
                        let match = try await s.folders().first {
                            $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                        }
                        let folder = match?.name ?? wanted
                        _ = try await scripts.run(Script.move, [note.scriptID, folder])
                        var result = ToolResult.text(
                            "Moved “\(note.title)” to “\(folder)”."
                                + (match == nil ? " The folder was new and has been made." : ""))
                        result.activity = "Claude moved the note “\(note.title)” to “\(folder)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_rename", title: "Rename a Note",
                    description:
                        "Changes a note's title (its first line), leaving the rest of the note as it is.",
                    input: [
                        "id": .stringParam("The note's id, from notes_find"),
                        "title": .stringParam("The new title"),
                    ], required: ["id", "title"], readOnly: false, deadlineMS: 30_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue, let title = args["title"]?.stringValue,
                            !title.isEmpty, !title.contains("\n")
                        else { return .text("Give the note's id and a one-line title.", isError: true) }
                        let note = try await s.read(id: id)
                        // Notes shows a note's first line as its title, so that line is changed,
                        // with the same care as edit (checked live 2026-11-01: setting only the
                        // note's name left the first line as it was).
                        guard s.knowsContents else {
                            return .text(
                                "Latchkey can't check this note for checklists or images with this version of Notes, so it doesn't change existing notes.",
                                isError: true)
                        }
                        if let why = refusal(note, replacing: false) { return .text(why, isError: true) }
                        if needsWindow(note) {
                            try await inWindow(scriptID: note.scriptID, noteID: note.id, window: window) { shown in
                                try await apply(
                                    NoteWindowEdit.rename(shown, to: title), to: shown, noteID: note.id,
                                    window: window, checklists: false)
                            }
                            let ending = await savedNote(window) { await changed(s, note) }
                            var result = ToolResult.text("Renamed “\(note.title)” to “\(title)”." + ending)
                            result.activity = "Claude renamed the note “\(note.title)” to “\(title)”"
                            return result
                        }
                        let body = try await scripts.run(Script.getBody, [note.scriptID])
                        let old = NoteHTML.escape(note.title)
                        let firstLineEnd = body.range(of: "</div>")?.lowerBound ?? body.endIndex
                        guard let at = body.range(of: old), at.upperBound <= firstLineEnd else {
                            return .text(
                                "The first line of “\(note.title)” isn't its title as plain text, so it wasn't renamed.",
                                isError: true)
                        }
                        _ = try await scripts.run(
                            Script.setBody,
                            [note.scriptID, body.replacingCharacters(in: at, with: NoteHTML.escape(title))])
                        var result = ToolResult.text("Renamed “\(note.title)” to “\(title)”.")
                        result.activity = "Claude renamed the note “\(note.title)” to “\(title)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_check", title: "Tick a Checklist Item",
                    description:
                        "Ticks or unticks a checklist item in a note. Notes comes forward for about a second to do it.",
                    input: [
                        "id": .stringParam("The note's id, from notes_find"),
                        "find": .stringParam("Text of the checklist item (part of it is enough when it's unique)"),
                        "checked": .boolParam("true ticks (default), false unticks"),
                    ], required: ["id", "find"], readOnly: false, deadlineMS: 60_000),
                handler: { args in
                    await run(store, scripts) { s in
                        guard let id = args["id"]?.stringValue, let find = args["find"]?.stringValue, !find.isEmpty
                        else { return .text("Give the note's id and the item's text.", isError: true) }
                        let wanted: Bool
                        if case .bool(let b) = args["checked"] { wanted = b } else { wanted = true }
                        let note = try await s.read(id: id)
                        if let why = refusal(note, replacing: false) { return .text(why, isError: true) }
                        let found: (at: Int, ticked: Bool, text: String)
                        switch NoteWindowEdit.item(find, markdown: note.text, text: nil) {
                        case .success(let f): found = f
                        case .failure(.notFound):
                            return .text("“\(note.title)” has no checklist item with “\(find)”.", isError: true)
                        case .failure(.several(let n)):
                            return .text(
                                "\(n) checklist items in “\(note.title)” have “\(find)”; give more of the item's text.",
                                isError: true)
                        }
                        let word = wanted ? "ticked" : "unticked"
                        if found.ticked == wanted {
                            return .text("“\(found.text)” is already \(word) in “\(note.title)”.")
                        }
                        try await inWindow(scriptID: note.scriptID, noteID: note.id, window: window) { shown in
                            guard case .success(let item) = NoteWindowEdit.item(find, markdown: note.text, text: shown)
                            else {
                                throw WindowFailure(
                                    message:
                                        "Notes' window doesn't show “\(found.text)” as Notes saved it; nothing was changed."
                                )
                            }
                            guard await window.markChecked(note.id, [item.at]) else {
                                throw WindowFailure(message: "Notes didn't tick “\(found.text)”.")
                            }
                        }
                        let ending = await savedNote(window) {
                            guard let now = try? await s.read(id: id),
                                case .success(let item) = NoteWindowEdit.item(find, markdown: now.text, text: nil)
                            else { return false }
                            return item.ticked == wanted
                        }
                        var result = ToolResult.text(
                            "\(wanted ? "Ticked" : "Unticked") “\(found.text)” in “\(note.title)”." + ending)
                        result.activity = "Claude \(word) “\(found.text)” in the note “\(note.title)”"
                        return result
                    }
                }),
            ToolEntry(
                tool: .make(
                    "notes_create_folder", title: "Create a Note Folder",
                    description: "Creates an empty folder in the default Notes account.",
                    input: ["folder": .stringParam("The new folder's name")], required: ["folder"],
                    readOnly: false, deadlineMS: 30_000),
                handler: { args in
                    guard let folder = args["folder"]?.stringValue, !folder.isEmpty else {
                        return .text("Give the folder's name.", isError: true)
                    }
                    do {
                        _ = try await scripts.run(Script.createFolder, [folder])
                        var result = ToolResult.text("Created the folder “\(folder)”.")
                        result.activity = "Claude created the Notes folder “\(folder)”"
                        result.made = "the Notes folder “\(folder)”"
                        return result
                    } catch ScriptError.failed(let message) where message.contains("LATCHKEY_FOLDER_EXISTS") {
                        return .text("There's already a folder named “\(folder)”.", isError: true)
                    } catch let failure as ScriptError {
                        return .text(explain(failure), isError: true)
                    } catch {
                        return .text("Notes couldn't create the folder: \(error.localizedDescription)", isError: true)
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
                        // Said deleted only once Notes' own database says so: with the Mac locked,
                        // Notes' scripting dropped a note its database still listed (2026-11-04).
                        var saved = false
                        for _ in 0..<20 {
                            do { _ = try await s.read(id: id) } catch NotesStore.Failure.noSuchNote(_) {
                                saved = true
                                break
                            } catch {}
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        guard saved else {
                            return .text(
                                "Notes took “\(note.title)” off its list but hasn't saved that yet, so it may come back (with the Mac locked, Notes can wait until it's unlocked). Check with notes_find in a minute.",
                                isError: true)
                        }
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
                        // Said deleted only once Notes' own database says so (2026-11-02: ten
                        // folders answered "deleted" stayed in Notes).
                        if let s = try? store() {
                            var saved = false
                            for _ in 0..<20 {
                                if let list = try? s.folders(), !list.contains(where: { $0.name == folder }) {
                                    saved = true
                                    break
                                }
                                try await Task.sleep(for: .milliseconds(250))
                            }
                            if !saved {
                                return .text(
                                    "Notes took the folder “\(folder)” off its list, but hasn't saved that yet, so it may come back. Check with notes_find in a minute.",
                                    isError: true)
                            }
                        }
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

    /// FR-106: why a note can't be changed without losing part of it, or nil. Since 2026-11-04
    /// only a locked note, and replacing the text of a note with images or tables.
    static func refusal(_ note: NotesStore.Note, replacing: Bool) -> String? {
        if note.locked {
            return
                "Latchkey didn't change “\(note.title)”: it's locked with a password. Ask the Mac's owner to change it in Notes."
        }
        if replacing, !note.attachments.isEmpty {
            return """
                Latchkey didn't replace the text of “\(note.title)”: it has images, tables, or other attachments, \
                which replacing would delete. Use edit to change a passage, or append.
                """
        }
        return nil
    }

    /// Whether AppleScript's rewrite would lose part of the note, so Notes' window is used (FR-155).
    static func needsWindow(_ note: NotesStore.Note) -> Bool {
        note.hasChecklists || note.hasInlineItems || !note.attachments.isEmpty
    }

    static func passage(_ problem: NoteWindowEdit.Problem, _ note: NotesStore.Note) -> String {
        switch problem {
        case .notFound:
            "The passage wasn't found in “\(note.title)”, or it spans formatting. Read the note again and give a shorter passage."
        case .several(let n): "The passage appears \(n) times in “\(note.title)”. Include more of the surrounding text."
        }
    }

    /// Notes' database shows the note changed since it was read.
    static func changed(_ s: any NotesReader, _ note: NotesStore.Note) async -> Bool {
        guard let now = try? await s.read(id: note.id) else { return false }
        return now.modified != note.modified || now.text != note.text
    }

    /// After AppleScript wrote ☐/☑ lines into a plain note, makes them real in Notes' window
    /// (FR-156); without the window they stay (FR-158). Answers the result's ending.
    static func realChecklists(
        _ note: NotesStore.Note, written: String, replace: Bool, _ window: NoteWindow, _ s: any NotesReader
    ) async -> String {
        let last = lastShownLine(written)
        let count = NoteWindowEdit.display(written).split(separator: "\n", omittingEmptySubsequences: false).count
        do {
            try await inWindow(
                scriptID: note.scriptID, noteID: note.id, window: window, ready: { $0.contains(last) }
            ) { shown in
                let ns = shown as NSString
                let region: NSRange
                if replace {
                    let newline = ns.range(of: "\n")
                    let start = newline.location == NSNotFound ? ns.length : newline.location + 1
                    region = NSRange(location: start, length: ns.length - start)
                } else {
                    region = NoteWindowEdit.lastLines(shown, count)
                }
                try await makeChecklists(shown, region: region, noteID: note.id, window: window)
            }
            return await savedNote(window) { (try? await s.read(id: note.id))?.hasChecklists == true }
        } catch let f as WindowFailure {
            return f.boxes
        } catch {
            return " Its checklist items are ☐ and ☑ characters for now: \(error.localizedDescription)"
        }
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
            if not (exists folder folderName) then make new folder at default account with properties {name:folderName}
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
        /// argv: note id, folder name (made in the default account when no folder has that name).
        static let move = """
            on run argv
            set theID to item 1 of argv
            set folderName to item 2 of argv
            tell application "Notes"
            if not (exists folder folderName) then make new folder at default account with properties {name:folderName}
            move note id theID to folder folderName
            end tell
            end run
            """
        static let createFolder = """
            on run argv
            set folderName to item 1 of argv
            tell application "Notes"
            set acc to default account
            if exists folder folderName of acc then error "LATCHKEY_FOLDER_EXISTS"
            make new folder at acc with properties {name:folderName}
            end tell
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
            -- Each note first, then the empty folder: a folder deleted with notes inside is gone
            -- from Notes' window but not saved, and comes back (2026-11-02, checked in its database).
            repeat with n in (get notes of f)
            delete n
            end repeat
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
