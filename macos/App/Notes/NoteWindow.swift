import AppKit
import ApplicationServices

/// Notes' own window (spec 002 plan D3a, FR-155 to FR-159): withdrawn on 2026-11-07 (Toni: Latchkey
/// never disturbs the Owner while the Mac is unlocked, and editing in Notes' window drives an app
/// they may be using). Only the switched-off `unavailable` window remains, so notes with
/// checklists, links, or images are refused (FR-106).
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
    /// Waits (up to 5 s) for the Owner to pause typing and the mouse, and answers whether they did:
    /// Notes is brought forward only then, so the Owner's typing never lands in a note (live check
    /// 2026-11-06: it did, and the note got "dia" and two empty items).
    var ownerQuiet: @Sendable () async -> Bool = { true }
    /// Whether the Owner typed or clicked while Notes was in front for the last change.
    var ownerActed: @Sendable () -> Bool = { false }
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
