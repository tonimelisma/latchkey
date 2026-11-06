// Runs Latchkey's real Notes window code (NoteWindow, NotesWindowRoute, NoteHTML) against the
// real Notes, the same steps notes_change takes for a note with checklists. Built by
// notes-check.sh. Usage:
//   notes-check create <title> <markdown>     prints the note's scripting id
//   notes-check append <scripting id> <markdown>
//   notes-check edit <scripting id> <find> <replacement>
//   notes-check tick <scripting id> <item text>
// Read the result back with Latchkey's notes_read (Notes' own database).
import AppKit
import Foundation

let args = CommandLine.arguments
let window = NoteWindow.live

/// The note's editor identifier (its id in Notes' database), from the editor Notes shows for it.
func editorID(_ scriptID: String) async throws -> String {
    _ = try await window.show(scriptID)
    for _ in 0..<50 {
        if let notes = NoteWindow.Live.notesApp() {
            let app = AXUIElementCreateApplication(notes.processIdentifier)
            var ws: AnyObject?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws)
            for w in (ws as? [AXUIElement]) ?? [] {
                if let id = find(w, 0) { return id }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw NotesCapability.WindowFailure.unavailable
}

func find(_ e: AXUIElement, _ depth: Int) -> String? {
    if let id = AppWindowReader.string(e, "AXIdentifier"), id.hasPrefix("Note[id=") {
        return String(id.dropFirst(8).dropLast())
    }
    guard depth < 30 else { return nil }
    var kids: AnyObject?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
    for k in (kids as? [AXUIElement]) ?? [] {
        if let id = find(k, depth + 1) { return id }
    }
    return nil
}

func run() async throws {
    guard args.count >= 3 else {
        print("usage: notes-check create|append|edit|tick …")
        exit(2)
    }
    switch args[1] {
    case "create":
        let html = NoteHTML.title(args[2]) + NoteHTML.from(args[3])
        let scriptID = try await OSAScriptRunner().run(
            "on run argv\ntell application \"Notes\" to return id of (make new note with properties {body:item 1 of argv})\nend run",
            [html])
        print(scriptID)
        let id = try await editorID(scriptID)
        let last = NotesCapability.lastShownLine(args[3])
        try await NotesCapability.inWindow(scriptID: scriptID, noteID: id, window: window, ready: { $0.contains(last) }) {
            shown in
            let ns = shown as NSString
            let newline = ns.range(of: "\n")
            let start = newline.location == NSNotFound ? ns.length : newline.location + 1
            try await NotesCapability.makeChecklists(
                shown, region: NSRange(location: start, length: ns.length - start), noteID: id, window: window)
        }
    case "append", "edit":
        let scriptID = args[2]
        let id = try await editorID(scriptID)
        try await NotesCapability.inWindow(scriptID: scriptID, noteID: id, window: window) { shown in
            let plan: NoteEditPlan
            if args[1] == "append" {
                plan = NoteWindowEdit.append(to: shown, NoteWindowEdit.display(args[3]))
            } else {
                guard case .success(let p) = NoteWindowEdit.edit(shown, find: args[3], with: args[4]) else {
                    throw NotesCapability.WindowFailure(message: "passage not found once")
                }
                plan = p
            }
            try await NotesCapability.apply(
                plan, to: shown, noteID: id, window: window, checklists: args[1] == "append")
        }
    case "tick":
        let scriptID = args[2]
        let id = try await editorID(scriptID)
        try await NotesCapability.inWindow(scriptID: scriptID, noteID: id, window: window) { shown in
            var at = 0
            for p in shown.components(separatedBy: "\n") {
                if p == args[3] {
                    guard await window.markChecked(id, [at]) else {
                        throw NotesCapability.WindowFailure(message: "Notes didn't tick it")
                    }
                    return
                }
                at += (p as NSString).length + 1
            }
            throw NotesCapability.WindowFailure(message: "no such item")
        }
    default:
        print("unknown command")
        exit(2)
    }
    print("OK")
}

do {
    try await run()
} catch let f as NotesCapability.WindowFailure {
    print("FAILED: \(f.message)")
    exit(1)
} catch {
    print("FAILED: \(error)")
    exit(1)
}
