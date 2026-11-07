import Foundation

/// The Notes tools Claude sees: find, read, change (consolidated 2026-10-23).
extension NotesCapability {
    static func readTools(store: @escaping StoreSource, scripts: (any ScriptRunner)? = nil) -> [ToolEntry] {
        let ops = Operations(readOperations(store: store, scripts: scripts))
        return [
            ToolEntry(
                tool: .make(
                    "notes_find", title: "Find Notes",
                    description:
                        "Finds notes in Apple Notes whose title or text contains the query, newest first, with each note's id for notes_read. With no query and no folder, lists the folders (with note counts) and the most recently changed notes.",
                    input: [
                        "query": .stringParam("Words to look for"),
                        "folder": .stringParam("Only notes in this folder"),
                        "limit": .integerParam("At most this many notes (default 20, up to 100)"),
                    ], readOnly: true, deadlineMS: 30_000),
                handler: { args in
                    let search = await ops.call("notes_search", args)
                    guard !args.hasAny("query", "folder") else { return search }
                    return await ops.call("notes_folders", .object([:])) + search
                }),
            ToolEntry(
                tool: .make(
                    "notes_read", title: "Read a Note",
                    description:
                        "Reads one note: title, folder, dates, and text as Markdown (checklists as - [ ] and - [x]). Long notes come in parts; pass offset to read on. Attached images appear as [image <id>]; pass that id as image to see the picture.",
                    input: [
                        "id": .stringParam("The note's id, from notes_find"),
                        "offset": .integerParam("Start at this character, from a previous answer"),
                        "image": .stringParam("An image's id from [image <id>], to see that image"),
                    ], required: ["id"], readOnly: true),
                handler: { args in
                    if let image = args["image"]?.stringValue, !image.isEmpty {
                        return await ops.call(
                            "notes_image", .object(["note": args["id"] ?? .null, "attachment": .string(image)]))
                    }
                    return await ops.call("notes_read", args)
                }),
        ]
    }

    static let changeActions = [
        "create", "append", "replace", "edit", "rename", "move", "delete", "create_folder",
        "delete_folder",
    ]

    static func writeTools(store: @escaping StoreSource, scripts: any ScriptRunner)
        -> [ToolEntry]
    {
        let ops = Operations(writeOperations(store: store, scripts: scripts))
        return [
            ToolEntry(
                tool: .make(
                    "notes_change", title: "Change Notes",
                    description: """
                        Creates, changes, or deletes a note in Apple Notes. action: create (title, text, folder), \
                        append (id, text: added at the end), replace (id, text: everything below the title), \
                        edit (id, find: an exact passage in one paragraph, text: its replacement), \
                        rename (id, title), move (id, folder: made if it doesn't exist, as for create), \
                        delete (id: moves the note to Recently Deleted for 30 days), create_folder (folder), \
                        delete_folder (folder: \
                        deletes that folder, its notes to Recently Deleted; not the default folder). Text is Markdown-like: \
                        # headings, - lists, 1. numbered lists; - [ ] and - [x] become ☐ and ☑ lines. Notes with \
                        checklists, links, or images can't be changed (rewriting them would lose those); create a \
                        new note instead.
                        """,
                    input: [
                        "action": .enumParam(changeActions, "What to do"),
                        "id": .stringParam("The note's id, from notes_find (not for create)"),
                        "title": .stringParam("For create and rename: the note's title"),
                        "text": .stringParam("The text to write"),
                        "find": .stringParam("For edit: the exact passage to replace"),
                        "folder": .stringParam(
                            "For create and move: the folder (made if it doesn't exist; create uses the default folder if left out); for create_folder and delete_folder: the folder"
                        ),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 30_000),
                handler: { args in
                    let action = args["action"]?.stringValue
                    switch action {
                    case "create": return await ops.call("notes_create", args)
                    case "append", "replace", "edit":
                        return await ops.call("notes_update", args.with(["mode": args["action"]]))
                    case "rename": return await ops.call("notes_rename", args)
                    case "move": return await ops.call("notes_move", args)
                    case "create_folder": return await ops.call("notes_create_folder", args)
                    case "delete": return await ops.call("notes_delete", args)
                    case "delete_folder": return await ops.call("notes_delete_folder", args)
                    default: return .unknown("action", action, allowed: changeActions)
                    }
                })
        ]
    }
}
