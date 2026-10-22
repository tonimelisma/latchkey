import Foundation

/// Apple Notes (spec 002 US1). Reading comes from Notes' database; changes arrive in increment 3.
enum NotesCapability {
    /// Opens the store on first use; nil while Latchkey lacks Full Disk Access.
    typealias StoreSource = @Sendable () throws -> NotesStore?

    static func make() -> Capability {
        let source = Opener()
        return Capability(
            id: CapabilityRegistry.notes, title: "Notes", summary: "Read, search, create, edit, and delete notes",
            readTools: readTools(store: { try source.store() }), writeTools: [])
    }

    static let noAccess = """
        Latchkey can't read Notes yet: macOS needs the Mac's owner to turn on Latchkey in \
        System Settings → Privacy & Security → Full Disk Access.
        """

    /// FR-151: results stay well within Claude's limit.
    static let maxText = 100_000

    static func readTools(store: @escaping StoreSource) -> [ToolEntry] {
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
                    await run(store) { s in
                        let limit = min(max(Int(args["limit"]?.numberValue ?? 20), 1), 100)
                        let hits = try s.search(
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
                    await run(store) { s in
                        let folders = try s.folders()
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
                        "Reads one note: title, folder, dates, and text as Markdown (checklists as - [ ] and - [x]). Attached images appear as [image <id>]; view them with notes_image.",
                    input: ["id": .stringParam("The note's id, from notes_search")], required: ["id"], readOnly: true),
                handler: { args in
                    await run(store) { s in
                        guard let id = args["id"]?.stringValue else {
                            return .text("Give the note's id.", isError: true)
                        }
                        let n = try s.read(id: id)
                        var text = n.text
                        var shortened = false
                        if text.count > maxText {
                            text = String(text.prefix(maxText))
                            shortened = true
                        }
                        var header =
                            "\(n.title) (id \(n.id); folder \(n.folder); changed \(n.modified.formatted(.iso8601)))"
                        if n.locked { header += "\nThis note is locked with a password; its content can't be read." }
                        if shortened { header += "\nThe note is long; this is its first \(maxText) characters." }
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
                    await run(store) { s in
                        guard let note = args["note"]?.stringValue, let attachment = args["attachment"]?.stringValue
                        else {
                            return .text("Give the note's id and the image's id.", isError: true)
                        }
                        let image = try s.image(note: note, attachment: attachment)
                        return .image(image.data, mimeType: image.mimeType)
                    }
                }),
        ]
    }

    // MARK: helpers

    private static func run(_ source: StoreSource, _ body: @Sendable (NotesStore) throws -> ToolResult) async
        -> ToolResult
    {
        do {
            guard let store = try source() else { return .text(noAccess, isError: true) }
            return try body(store)
        } catch let failure as NotesStore.Failure {
            return .text(explain(failure), isError: true)
        } catch {
            return .text("Notes couldn't be read: \(error.localizedDescription)", isError: true)
        }
    }

    static func explain(_ f: NotesStore.Failure) -> String {
        switch f {
        case .cannotOpen: noAccess
        case .unknownLayout(let why): "This version of Notes stores notes in a way Latchkey doesn't know yet (\(why))."
        case .noSuchNote(let id): "There is no note with id \(id). Search again with notes_search."
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
