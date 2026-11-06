import AppKit
import ApplicationServices

/// Notes' own window, driven through Accessibility (spec 002 plan D3a, FR-155 to FR-159). Text
/// goes in at a place in the note's editor, as typing would, in the background, so the
/// checklists, links, and images around it stay. Checklists and ticks are made with Notes' Format
/// menu, which works only while Notes is in front: Notes comes forward for a moment (the
/// toolbar's Checklist button, pressed in the background, acted on a stale caret and mangled a
/// note on 2026-11-05).
struct NoteWindow: Sendable {
    /// Shows the note in Notes' main window without bringing Notes forward; answers the
    /// scripting ids of the notes shown before.
    var show: @Sendable (_ scriptID: String) async throws -> [String]
    /// Shows those notes again.
    var restore: @Sendable (_ scriptIDs: [String]) async -> Void
    /// The editor's text once it shows the note and `ready` accepts the text; nil if it doesn't.
    var open: @Sendable (_ noteID: String, _ ready: @escaping @Sendable (String) -> Bool) async -> String?
    /// Replaces a range (UTF-16) of the editor's text.
    var replace: @Sendable (_ noteID: String, _ range: NSRange, _ text: String) -> Bool
    /// Whether each paragraph starting at these places is a checklist item, read in the
    /// background (the Checklist button's state follows the caret); nil if it can't be read.
    var checklistStates: @Sendable (_ noteID: String, _ at: [Int]) async -> [Bool]?
    /// Makes each paragraph a checklist item or not, and ticks the ones asked, with Notes in
    /// front for a moment and the app that was in front given it back.
    var format: @Sendable (_ noteID: String, _ changes: [ParagraphFormat]) async -> Bool
    /// Ticks or unticks the items at these places (Notes comes forward for a moment).
    var markChecked: @Sendable (_ noteID: String, _ at: [Int]) async -> Bool
    /// Deletes the note the window shows through Notes' own Edit → Delete Note (Notes comes
    /// forward for a moment); false when the window can't, so the scripted delete is used.
    var deleteNote: @Sendable (_ noteID: String) async -> Bool = { _ in false }
    /// Waits until `check` sees the change in Notes' database.
    var saved: @Sendable (_ check: @escaping @Sendable () async -> Bool) async -> Bool
    /// Whether the Mac is locked: Notes' window then has no note editor (checked live
    /// 2026-11-04), so nothing is tried.
    var locked: @Sendable () -> Bool = { false }
    /// Whether changes go through Notes' window at all. Off in the app until checklist editing
    /// works on real Notes (the live check of 2026-11-05 mangled a test note); then notes with
    /// checklists, links, or images are refused as before (FR-106) and Claude's checklist items
    /// stay ☐ and ☑.
    var enabled = true

    /// No window: the AppleScript route only (what the app uses while window editing is off).
    static let unavailable = NoteWindow(
        show: { _ in [] }, restore: { _ in }, open: { _, _ in nil }, replace: { _, _, _ in false },
        checklistStates: { _, _ in nil }, format: { _, _ in false }, markChecked: { _, _ in false },
        saved: { _ in false }, enabled: false)

    static let live = NoteWindow(
        show: { scriptID in
            // The app in front before anything happens: showing a note can itself bring Notes
            // forward, and then the front was never given back (2026-11-06).
            Live.ownerFront.withLock { $0 = Live.frontApp() }
            let out = try await OSAScriptRunner(app: Permissions.notesApp).run(Script.show, [scriptID])
            return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        },
        restore: { ids in
            if let first = ids.first {
                _ = try? await OSAScriptRunner(app: Permissions.notesApp).run(Script.restore, [first])
            }
            // Whatever brought Notes forward, the Owner's app gets the front back.
            let owner = Live.ownerFront.withLock { held in
                defer { held = nil }
                return held
            }
            // Notes' `show` brings Notes forward a moment after the script returns (seen
            // 2026-11-06), so watch for up to 1.5 s and give the front back each time it does,
            // until the Owner's app has held it for 300 ms.
            guard let owner, let notes = Live.notesApp(), owner != notes else { return }
            var held = 0
            for _ in 0..<30 where held < 6 {
                if Live.frontApp()?.processIdentifier == notes.processIdentifier {
                    held = 0
                    _ = await Live.bringForward(owner)
                } else {
                    held += 1
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        },
        open: { noteID, ready in
            // At most 5 s however slowly Notes answers (each look took up to 2 s while locked).
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let editor = Live.editor(noteID), let text = AppWindowReader.string(editor, kAXValueAttribute),
                    ready(text)
                {
                    return text
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        },
        replace: { noteID, range, text in
            guard let editor = Live.editor(noteID),
                Live.select(editor, NSRange(location: range.location, length: range.length))
            else { return false }
            return AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, text as CFString)
                == .success
        },
        checklistStates: { noteID, places in
            var states: [Bool] = []
            for at in places {
                guard let editor = Live.editor(noteID), Live.select(editor, NSRange(location: at, length: 0)) else {
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard let on = Live.checklistOn() else { return nil }
                states.append(on)
            }
            return states
        },
        format: { noteID, changes in
            await Live.inFront {
                for change in changes {
                    guard let editor = Live.editor(noteID),
                        Live.caret(editor, at: change.at)
                    else {
                        NotesLog.record("the note's editor or caret wasn't there with Notes in front", error: true)
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    if let want = change.checklist {
                        guard let now = Live.checklistOn() else {
                            NotesLog.record("the Checklist button wasn't found", error: true)
                            return false
                        }
                        if now != want {
                            guard await Live.pressMenu(char: "L", modifiers: 1) else { return false }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                    if change.tick {
                        guard Live.caret(editor, at: change.at), await Live.pressMenu(char: "U", modifiers: 1)
                        else { return false }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                return true
            }
        },
        markChecked: { noteID, places in
            await Live.inFront {
                for at in places {
                    guard let editor = Live.editor(noteID), Live.caret(editor, at: at) else {
                        NotesLog.record("the note's editor or caret wasn't there with Notes in front", error: true)
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    // Once more: the first focus can go to a window that wasn't key yet.
                    _ = Live.caret(editor, at: at)
                    try? await Task.sleep(for: .milliseconds(200))
                    guard await Live.pressMenu(char: "U", modifiers: 1) else {
                        NotesLog.record(
                            "the editor \(Live.isFocused(editor) ? "had" : "didn't have") the focus", error: true)
                        return false
                    }
                }
                return true
            }
        },
        deleteNote: { await Live.deleteShown($0) },
        saved: { check in
            for _ in 0..<25 {
                if await check() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        },
        locked: { SystemScreen().isLocked() })

    enum Script {
        /// argv: the note's scripting id. Answers the notes selected before, one per line.
        static let show = """
            on run argv
            set theID to item 1 of argv
            tell application "Notes"
            set previousIDs to {}
            try
            repeat with s in (get selection)
            set end of previousIDs to (id of s)
            end repeat
            end try
            show note id theID
            set AppleScript's text item delimiters to linefeed
            return previousIDs as text
            end tell
            end run
            """
        static let restore = """
            on run argv
            set theID to item 1 of argv
            tell application "Notes"
            try
            show note id theID
            end try
            end tell
            end run
            """
    }

    /// Accessibility lookups in Notes' windows.
    enum Live {
        static func notesApp() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first
        }

        private static func application() -> AXUIElement? {
            guard AXIsProcessTrusted(), let app = notesApp() else { return nil }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 2)
            return ax
        }

        private static func children(_ e: AXUIElement) -> [AXUIElement] {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else {
                return []
            }
            return (v as? [AXUIElement]) ?? []
        }

        private static func first(in e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
            if match(e) { return e }
            guard depth < 30 else { return nil }
            for c in children(e) {
                if let found = first(in: c, depth: depth + 1, match) { return found }
            }
            return nil
        }

        private static func windows() -> [AXUIElement] {
            guard let app = application() else { return [] }
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success else {
                return []
            }
            return (v as? [AXUIElement]) ?? []
        }

        /// The note's editor: Notes names it `Note[id=<the note's id>]`.
        static func editor(_ noteID: String) -> AXUIElement? {
            let wanted = "Note[id=\(noteID)]"
            for w in windows() {
                if let e = first(in: w, { AppWindowReader.string($0, "AXIdentifier") == wanted }) { return e }
            }
            return nil
        }

        /// Gives the editor the keyboard focus, then puts the caret at a place: a menu command acts
        /// where the focused editor's caret is, and without the focus Notes used its own older
        /// caret (the end of the note; seen 2026-11-05).
        static func isFocused(_ editor: AXUIElement) -> Bool {
            AppWindowReader.string(editor, kAXFocusedAttribute) == "1"
        }

        static func caret(_ editor: AXUIElement, at: Int) -> Bool {
            _ = AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return select(editor, NSRange(location: at, length: 0))
        }

        static func select(_ editor: AXUIElement, _ range: NSRange) -> Bool {
            var r = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &r) else { return false }
            return AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }

        /// A menu item by its shortcut (`modifiers` as Accessibility counts them: 1 is ⇧⌘), so
        /// it's found in any language.
        static func menuItem(char: String, modifiers: Int) -> AXUIElement? {
            guard let app = application() else { return nil }
            var bar: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
                CFGetTypeID(bar) == AXUIElementGetTypeID()
            else { return nil }
            return first(in: bar as! AXUIElement) {
                AppWindowReader.string($0, "AXMenuItemCmdChar") == char
                    && AppWindowReader.string($0, "AXMenuItemCmdModifiers") == String(modifiers)
            }
        }

        /// Runs `work` with Notes in front, then gives the front back to the app that had it.
        /// The Owner's app in front when the change began (set by `show`, used by `restore`).
        static let ownerFront = NSLockedBox<NSRunningApplication?>(nil)

        static func inFront(_ work: () async -> Bool) async -> Bool {
            guard let notes = notesApp() else { return false }
            let previous = ownerFront.withLock { $0 } ?? frontApp()
            var done = false
            if await bringForward(notes) {
                // Notes' window takes a moment to become the one keys and menus go to.
                try? await Task.sleep(for: .milliseconds(300))
                done = await work()
            }
            // The front goes back to the app that had it (2026-11-06: a plain activate from the
            // installed app was refused and Notes stayed in front).
            if let previous, previous != notes { _ = await bringForward(previous) }
            return done
        }

        /// Brings an app to the front and answers whether it is there. macOS may refuse a plain
        /// activate from a menu bar app in the background (the installed app's was, 2026-11-06);
        /// opening the app through LaunchServices, then AppleScript's activate, are the fallbacks.
        /// Whether it's in front is asked of the app itself: NSWorkspace's frontmost app is updated
        /// by a run loop that isn't turning here, and read stale (seen 2026-11-05).
        static func bringForward(_ target: NSRunningApplication) async -> Bool {
            let app = AXUIElementCreateApplication(target.processIdentifier)
            func isFront() async -> Bool {
                // Up to 2 s. Both the app and the system must agree: Claude's app said it was in
                // front while Notes still was (2026-11-06).
                for _ in 0..<40 {
                    if AppWindowReader.string(app, kAXFrontmostAttribute) == "1",
                        frontApp()?.processIdentifier == target.processIdentifier
                    {
                        return true
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return false
            }
            let name = target.bundleIdentifier ?? "an app"
            target.activate()
            if await isFront() {
                NotesLog.record("brought \(name) forward with activate")
                return true
            }
            // `open -b`, as computer_act's open_app does: a program of its own asks LaunchServices,
            // which brought Notes forward when the installed app's activate and its
            // NSWorkspace.openApplication were both refused (2026-11-06).
            if let id = target.bundleIdentifier {
                await openByID(id)
                if await isFront() {
                    NotesLog.record("brought \(name) forward with open -b")
                    return true
                }
            }
            NotesLog.record("couldn't bring \(name) forward", error: true)
            return false
        }

        /// The app in front, asked of Accessibility: NSWorkspace's answer was stale in the installed
        /// app, so Notes was taken for the app in front and the front never went back (2026-11-06).
        static func frontApp() -> NSRunningApplication? {
            var v: AnyObject?
            guard
                AXUIElementCopyAttributeValue(
                    AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v) == .success,
                let v, CFGetTypeID(v) == AXUIElementGetTypeID()
            else { return NSWorkspace.shared.frontmostApplication }
            var pid: pid_t = 0
            AXUIElementGetPid(v as! AXUIElement, &pid)
            return NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.frontmostApplication
        }

        /// Runs `/usr/bin/open -b <id>` and waits up to 5 s for it, without blocking a thread.
        static func openByID(_ id: String) async {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/open")
            p.arguments = ["-b", id]
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let once = OnceFlag()
                p.terminationHandler = { _ in if once.claim() { done.resume() } }
                do { try p.run() } catch {
                    if once.claim() { done.resume() }
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if once.claim() {
                        p.terminate()
                        done.resume()
                    }
                }
            }
        }

        /// Lets exactly one of several callbacks go on.
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if claimed { return false }
                claimed = true
                return true
            }
        }

        /// Deletes the note the window shows through Edit → Delete Note, with Notes in front for a
        /// moment: Notes saves that at once, where a scripted delete sometimes stayed unsaved for
        /// minutes (2026-11-06). Only when the editor shows exactly this note, so the note selected
        /// in the list is it.
        static func deleteShown(_ noteID: String) async -> Bool {
            guard editor(noteID) != nil else { return false }
            return await inFront {
                guard let w = windows().first,
                    let list = first(
                        in: w, { AppWindowReader.string($0, kAXDescriptionAttribute) == "My Notes as List" }),
                    editor(noteID) != nil
                else { return false }
                _ = AXUIElementSetAttributeValue(list, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(200))
                return await pressMenu(char: "\u{8}", modifiers: 8)
            }
        }

        /// Presses a menu item by its shortcut once Notes has enabled it for the caret.
        static func pressMenu(char: String, modifiers: Int) async -> Bool {
            let what = char == "L" ? "Checklist" : char == "U" ? "Mark as Checked" : "Delete Note"
            guard let item = menuItem(char: char, modifiers: modifiers) else {
                NotesLog.record("menu item \(what) not found", error: true)
                return false
            }
            for _ in 0..<80 {  // up to 2 s: the menu follows the caret a moment later
                if AppWindowReader.string(item, kAXEnabledAttribute) == "1" {
                    let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    if !pressed { NotesLog.record("menu item \(what) didn't take the press", error: true) }
                    return pressed
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            NotesLog.record("menu item \(what) stayed unavailable for 2 s", error: true)
            return false
        }

        /// Whether the paragraph at the caret is a checklist item: the toolbar button's state.
        static func checklistOn() -> Bool? {
            guard let button = checklistButton() else { return nil }
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(button, kAXValueAttribute as CFString, &v) == .success else {
                return nil
            }
            if let n = v as? NSNumber { return n.boolValue }
            if let s = v as? String { return s == "On" || s == "1" }
            return nil
        }

        /// The toolbar's Checklist button: named like the Format menu's ⇧⌘L item.
        static func checklistButton() -> AXUIElement? {
            let name =
                menuItem(char: "L", modifiers: 1).flatMap { AppWindowReader.string($0, kAXTitleAttribute) }
                ?? "Checklist"
            for w in windows() {
                if let b = first(
                    in: w,
                    {
                        AppWindowReader.string($0, kAXRoleAttribute) == "AXButton"
                            && AppWindowReader.string($0, kAXDescriptionAttribute) == name
                    })
                {
                    return b
                }
            }
            return nil
        }
    }
}

/// A value behind a lock (here: the Owner's app in front, kept between `show` and `restore`).
final class NSLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// One paragraph's wanted format: a checklist item or not (nil leaves it), and ticked.
struct ParagraphFormat: Sendable, Equatable {
    var at: Int
    var checklist: Bool?
    var tick = false
}

/// Where a change goes in the editor's text, in UTF-16 units as Accessibility counts
/// (spec 002 plan D3a). Pure, so it's tested without Notes.
struct NoteEditPlan: Equatable {
    var range: NSRange
    var text: String
    /// The written text's place once the change is made.
    var region: NSRange
}

enum NoteWindowEdit {
    enum Problem: Error, Equatable {
        case notFound
        case several(Int)
    }

    enum Mark: Equatable {
        case open, ticked
    }

    /// Markdown-like text as lines the editor takes: checklist items as ☐/☑ lines (made real
    /// afterwards), bullets as •, headings as their text.
    static func display(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw.drop { $0 == " " })
            if line.hasPrefix("- [ ] ") { return "☐ " + line.dropFirst(6) }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return "☑ " + line.dropFirst(6) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return "• " + line.dropFirst(2) }
            for level in (1...3).reversed() where line.hasPrefix(String(repeating: "#", count: level) + " ") {
                return String(line.dropFirst(level + 1))
            }
            return String(raw)
        }.joined(separator: "\n")
    }

    /// The text's end, before the newline Notes keeps after the last paragraph.
    private static func end(_ text: NSString) -> Int {
        text.hasSuffix("\n") ? text.length - 1 : text.length
    }

    static func append(to text: String, _ written: String) -> NoteEditPlan {
        let at = end(text as NSString)
        return NoteEditPlan(
            range: NSRange(location: at, length: 0), text: "\n" + written,
            region: NSRange(location: at + 1, length: (written as NSString).length))
    }

    /// Everything below the first line; a note with only its title is appended to.
    static func replaceBody(of text: String, with written: String) -> NoteEditPlan {
        let ns = text as NSString
        let newline = ns.range(of: "\n")
        let start = newline.location == NSNotFound ? ns.length + 1 : newline.location + 1
        let stop = end(ns)
        guard start <= stop else { return append(to: text, written) }
        return NoteEditPlan(
            range: NSRange(location: start, length: stop - start), text: written,
            region: NSRange(location: start, length: (written as NSString).length))
    }

    static func edit(_ text: String, find: String, with replacement: String) -> Result<NoteEditPlan, Problem> {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: find, options: [], range: search)
            guard r.location != NSNotFound else { break }
            ranges.append(r)
            search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        guard let r = ranges.first else { return .failure(.notFound) }
        guard ranges.count == 1 else { return .failure(.several(ranges.count)) }
        return .success(
            NoteEditPlan(
                range: r, text: replacement,
                region: NSRange(location: r.location, length: (replacement as NSString).length)))
    }

    static func rename(_ text: String, to title: String) -> NoteEditPlan {
        let ns = text as NSString
        let newline = ns.range(of: "\n")
        let length = newline.location == NSNotFound ? end(ns) : newline.location
        return NoteEditPlan(
            range: NSRange(location: 0, length: length), text: title,
            region: NSRange(location: 0, length: (title as NSString).length))
    }

    /// The paragraphs starting in a region, with their ☐/☑ mark.
    static func lines(in text: String, region: NSRange) -> [(at: Int, mark: Mark?)] {
        let ns = text as NSString
        var out: [(at: Int, mark: Mark?)] = []
        var at = region.location
        while at < region.upperBound, at <= ns.length {
            let rest = ns.substring(from: at)
            out.append((at, rest.hasPrefix("☐ ") ? .open : rest.hasPrefix("☑ ") ? .ticked : nil))
            let next = ns.range(of: "\n", options: [], range: NSRange(location: at, length: ns.length - at))
            guard next.location != NSNotFound else { break }
            at = next.location + 1
        }
        return out
    }

    /// The paragraphs a note's last `count` lines take.
    static func lastLines(_ text: String, _ count: Int) -> NSRange {
        let ns = text as NSString
        let stop = end(ns)
        var at = stop
        var seen = 0
        while at > 0 {
            if ns.character(at: at - 1) == 0x0A {
                seen += 1
                if seen == count { break }
            }
            at -= 1
        }
        return NSRange(location: at, length: stop - at)
    }

    /// A Markdown line's text without its list, checklist, or heading mark.
    private static func content(_ line: Substring) -> (text: String, mark: Mark?) {
        let l = line.drop { $0 == " " }
        if l.hasPrefix("- [ ] ") { return (String(l.dropFirst(6)), .open) }
        if l.hasPrefix("- [x] ") { return (String(l.dropFirst(6)), .ticked) }
        if l.hasPrefix("- ") { return (String(l.dropFirst(2)), nil) }
        for level in (1...3).reversed() where l.hasPrefix(String(repeating: "#", count: level) + " ") {
            return (String(l.dropFirst(level + 1)), nil)
        }
        if let dot = l.firstIndex(of: "."), dot > l.startIndex, l[..<dot].allSatisfy(\.isNumber),
            l[l.index(after: dot)...].hasPrefix(" ")
        {
            return (String(l[l.index(dot, offsetBy: 2)...]), nil)
        }
        return (String(l), nil)
    }

    /// The checklist item whose text has `find` (any case): whether it's ticked, from the
    /// database's Markdown, and where its paragraph starts in the editor's `text` (-1 without).
    static func item(_ find: String, markdown: String, text: String?) -> Result<
        (at: Int, ticked: Bool, text: String), Problem
    > {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(content)
        let hits = lines.indices.filter {
            lines[$0].mark != nil && lines[$0].text.range(of: find, options: .caseInsensitive) != nil
        }
        guard let hit = hits.first else { return .failure(.notFound) }
        guard hits.count == 1 else { return .failure(.several(hits.count)) }
        let wanted = lines[hit].text
        let ticked = lines[hit].mark == .ticked
        guard let text else { return .success((-1, ticked, wanted)) }
        // The same text may stand on other lines too: the k-th such paragraph is this one.
        let k = lines[..<hit].filter { $0.text == wanted }.count
        var seen = 0
        var at = 0
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph == wanted {
                if seen == k { return .success((at, ticked, wanted)) }
                seen += 1
            }
            at += (paragraph as NSString).length + 1
        }
        return .failure(.notFound)
    }
}
