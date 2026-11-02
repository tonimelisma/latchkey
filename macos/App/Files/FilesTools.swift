import Foundation

/// The Files tools Claude sees: find, read, change (consolidated 2026-10-23).
extension FilesCapability {
    static func readTools(home: URL, commands: any CommandRunner) -> [ToolEntry] {
        let ops = Operations(readOperations(home: home, commands: commands))
        return [
            ToolEntry(
                tool: .make(
                    "files_find", title: "Find Files",
                    description:
                        "Finds files on the Mac. With query: searches names and contents with Spotlight, newest first (inside path, if given). Without query: lists the folder at path (the home folder if empty), or shows a file's details. Paths may start with ~; others are taken from the home folder. Spotlight skips hidden and excluded folders; list those instead.",
                    input: [
                        "query": .stringParam("Words in the file's name or content"),
                        "path": .stringParam("The folder to list or search in, or a file to describe"),
                        "hidden": .boolParam("When listing: include hidden files"),
                        "limit": .integerParam("When searching: at most this many files (default 30, up to 200)"),
                    ], readOnly: true, deadlineMS: 30_000),
                handler: { args in
                    if args.hasAny("query") {
                        return await ops.call("files_search", args.with(["folder": args["path"]]))
                    }
                    var isDir: ObjCBool = true
                    let url = resolve(args["path"]?.stringValue ?? "", home: home)
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                        return await ops.call("files_info", args)
                    }
                    return await ops.call("files_list", args)
                }),
            ToolEntry(
                tool: .make(
                    "files_read", title: "Read a File",
                    description:
                        "Reads a file: text, the text of PDFs and documents (Word, RTF, HTML), or an image, which is shown. Long text comes in parts; pass offset to read on. A PDF without text (a scan) is shown as a picture of a page; offset picks the page (from 0).",
                    input: [
                        "path": .stringParam("The file"),
                        "offset": .integerParam("Start at this character, from a previous answer"),
                    ], required: ["path"], readOnly: true, deadlineMS: 30_000),
                handler: { args in await ops.call("files_read", args) }),
        ]
    }

    static let changeActions = ["write", "append", "edit", "create_folder", "move", "copy", "trash"]

    static func writeTools(home: URL, own: OwnFiles = .standard) -> [ToolEntry] {
        let ops = Operations(writeOperations(home: home, own: own))
        return [
            ToolEntry(
                tool: .make(
                    "files_change", title: "Change Files",
                    description: """
                        Changes files on the Mac. action: write (path, text; an existing file only with \
                        overwrite), append (path, text: added at the end), edit (path, find: an exact passage \
                        that appears once, text: its replacement), create_folder (path), move or copy (path, \
                        to: the new path or a folder to put it in; never replaces an existing file), trash \
                        (path: moves it to the Trash, where it can be put back).
                        """,
                    input: [
                        "action": .enumParam(changeActions, "What to do"),
                        "path": .stringParam("The file or folder"),
                        "text": .stringParam("The text to write, add, or put in place of find"),
                        "find": .stringParam("For edit: the exact passage to replace"),
                        "to": .stringParam("For move and copy: where to"),
                        "overwrite": .boolParam("For write: replace an existing file"),
                    ], required: ["action", "path"], readOnly: false, destructive: true),
                handler: { args in
                    let action = args["action"]?.stringValue
                    switch action {
                    case "write": return await ops.call("files_write", args.with(["append": nil]))
                    case "append": return await ops.call("files_write", args.with(["append": .bool(true)]))
                    case "edit": return await ops.call("files_edit", args.with(["replace": args["text"]]))
                    case "create_folder": return await ops.call("files_create_folder", args)
                    case "move": return await ops.call("files_move", args.with(["from": args["path"]]))
                    case "copy": return await ops.call("files_copy", args.with(["from": args["path"]]))
                    case "trash": return await ops.call("files_trash", args)
                    default: return .unknown("action", action, allowed: changeActions)
                    }
                })
        ]
    }
}
