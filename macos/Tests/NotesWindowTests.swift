import Foundation
import Testing

@testable import Latchkey

/// Stands in for Notes' window (spec 002 plan D3a): the editor's text, which paragraphs are
/// checklist items and which are ticked, and every press Latchkey makes.
final class FakeNoteWindow: @unchecked Sendable {
    private let lock = NSLock()
    var texts: [String: String] = [:]
    /// Per note, per paragraph: (checklist, ticked).
    var styles: [String: [(Bool, Bool)]] = [:]
    var available = true
    var saved = true
    var locked = false
    private(set) var shown: [String] = []
    private(set) var restored: [[String]] = []
    private(set) var toggles: [Int] = []
    private(set) var marked: [Int] = []
    private(set) var replaced = 0
    private var caret = 0
    private var caretNote = ""

    init(_ notes: [String: String] = [:]) {
        for (id, text) in notes { set(id, text) }
    }

    func set(_ id: String, _ text: String, checklists: [Int: Bool] = [:]) {
        lock.withLock {
            texts[id] = text
            let count = text.components(separatedBy: "\n").count
            styles[id] = (0..<count).map { checklists[$0].map { (true, $0) } ?? (false, false) }
        }
    }

    func text(_ id: String) -> String { lock.withLock { texts[id] ?? "" } }

    /// Paragraphs of a note: (text, checklist, ticked).
    func paragraphs(_ id: String) -> [(String, Bool, Bool)] {
        lock.withLock {
            let lines = (texts[id] ?? "").components(separatedBy: "\n")
            return lines.enumerated().map { i, l in
                let s = styles[id]?[safe: i] ?? (false, false)
                return (l, s.0, s.1)
            }
        }
    }

    private func paragraph(_ id: String, at: Int) -> Int {
        let ns = (texts[id] ?? "") as NSString
        return ns.substring(to: min(at, ns.length)).components(separatedBy: "\n").count - 1
    }

    var window: NoteWindow {
        NoteWindow(
            show: { id in
                self.lock.withLock { self.shown.append(id) }
                return ["x-coredata://STORE-UUID/ICNote/p99"]
            },
            restore: { ids in self.lock.withLock { self.restored.append(ids) } },
            open: { id, ready in
                self.lock.withLock {
                    guard self.available, let t = self.texts[id], ready(t) else { return nil }
                    return t
                }
            },
            replace: { id, range, new in
                self.lock.withLock {
                    guard let t = self.texts[id] else { return false }
                    let p = self.paragraph(id, at: range.location)
                    let removed = ((t as NSString).substring(with: range)).filter { $0 == "\n" }.count
                    let added = new.filter { $0 == "\n" }.count
                    var s = self.styles[id] ?? []
                    let inherited = s[safe: p] ?? (false, false)
                    s.removeSubrange((p + 1)..<min(s.count, p + 1 + removed))
                    s.insert(contentsOf: Array(repeating: (inherited.0, false), count: added), at: min(p + 1, s.count))
                    self.styles[id] = s
                    self.texts[id] = (t as NSString).replacingCharacters(in: range, with: new)
                    self.replaced += 1
                    return true
                }
            },
            isChecklist: { id, at in
                self.lock.withLock {
                    self.caret = at
                    self.caretNote = id
                    return self.styles[id]?[safe: self.paragraph(id, at: at)]?.0
                }
            },
            toggleChecklist: { id in
                self.lock.withLock {
                    let p = self.paragraph(id, at: self.caret)
                    self.toggles.append(self.caret)
                    self.styles[id]?[p].0.toggle()
                    self.styles[id]?[p].1 = false
                    return true
                }
            },
            markChecked: { id, places in
                self.lock.withLock {
                    for at in places {
                        let p = self.paragraph(id, at: at)
                        self.marked.append(at)
                        self.styles[id]?[p].1.toggle()
                    }
                    return true
                }
            },
            saved: { _ in self.lock.withLock { self.saved } },
            locked: { self.lock.withLock { self.locked } })
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

@Suite struct NoteWindowEditTests {
    @Test func checklistsAndListsBecomeLinesTheWindowTakes() {
        #expect(
            NoteWindowEdit.display("# Plan\n- [ ] eggs\n- [x] milk\n- one\n* two\n1. first\nplain")
                == "Plan\n☐ eggs\n☑ milk\n• one\n• two\n1. first\nplain")
    }

    @Test func appendGoesAfterTheLastParagraph() {
        let plan = NoteWindowEdit.append(to: "Groceries\nMilk\n", "☐ eggs\nnote")
        #expect(plan.range == NSRange(location: 14, length: 0))
        #expect(plan.text == "\n☐ eggs\nnote")
        #expect(plan.region == NSRange(location: 15, length: 11))
        let noNewline = NoteWindowEdit.append(to: "Groceries\nMilk", "x")
        #expect(noNewline.range == NSRange(location: 14, length: 0))
    }

    @Test func replaceKeepsTheTitleLine() {
        let plan = NoteWindowEdit.replaceBody(of: "Trip\nold\nlines\n", with: "new")
        #expect(plan.range == NSRange(location: 5, length: 9))
        #expect(plan.text == "new")
        #expect(plan.region == NSRange(location: 5, length: 3))
        let titleOnly = NoteWindowEdit.replaceBody(of: "Trip\n", with: "new")
        #expect(titleOnly.range == NSRange(location: 4, length: 0))
        #expect(titleOnly.text == "\nnew")
    }

    @Test func editNeedsThePassageOnce() throws {
        let text = "Groceries\nMilk\nBread \u{FFFC} rye\n"
        let plan = try NoteWindowEdit.edit(text, find: "Bread", with: "Rye bread").get()
        #expect(plan.range == NSRange(location: 15, length: 5))
        #expect(plan.text == "Rye bread")
        #expect(throws: NoteWindowEdit.Problem.notFound) {
            try NoteWindowEdit.edit(text, find: "Eggs", with: "x").get()
        }
        #expect(throws: NoteWindowEdit.Problem.several(2)) {
            try NoteWindowEdit.edit("a\na\n", find: "a", with: "b").get()
        }
    }

    @Test func renameChangesTheFirstLine() {
        let plan = NoteWindowEdit.rename("Groceries\nMilk\n", to: "Shopping")
        #expect(plan.range == NSRange(location: 0, length: 9))
        #expect(plan.text == "Shopping")
    }

    @Test func findsTheChecklistLinesWritten() {
        let text = "T\n☐ eggs\nplain\n☑ milk\n"
        let lines = NoteWindowEdit.lines(in: text, region: NSRange(location: 2, length: 20))
        #expect(lines.map { $0.at } == [2, 9, 15])
        #expect(lines.map { $0.mark } == [.open, nil, .ticked])
    }

    @Test func findsAChecklistItemByItsText() throws {
        let markdown = "# Groceries\n- [x] Milk\n- [ ] Bread\nBread\nShop on Saturday"
        let text = "Groceries\nMilk\nBread\nBread\nShop on Saturday\n"
        let item = try NoteWindowEdit.item("Brea", markdown: markdown, text: text).get()
        #expect(item.at == 15)
        #expect(item.ticked == false)
        #expect(try NoteWindowEdit.item("milk", markdown: markdown, text: text).get().ticked == true)
        #expect(throws: NoteWindowEdit.Problem.notFound) {
            try NoteWindowEdit.item("Saturday", markdown: markdown, text: text).get()
        }
        let twice = "- [ ] a1\n- [ ] a2"
        #expect(throws: NoteWindowEdit.Problem.several(2)) {
            try NoteWindowEdit.item("a", markdown: twice, text: "a1\na2\n").get()
        }
    }

    @Test func aRepeatedItemIsFoundInItsOwnPlace() throws {
        // The same text as a plain line first, then as the checklist item.
        let markdown = "# T\nMilk\n- [ ] Milk"
        let item = try NoteWindowEdit.item("Milk", markdown: markdown, text: "T\nMilk\nMilk\n").get()
        #expect(item.at == 7)
    }
}

@Suite struct NotesWindowToolTests {
    let groceries = "Groceries\nMilk\nBread\nShop on Saturday\n"

    func setup(_ window: FakeNoteWindow) throws -> (FakeScripts, [String: ToolEntry]) {
        let store = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        let tools = NotesCapability.writeOperations(store: { store }, scripts: fake, window: window.window)
        return (fake, Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) }))
    }

    func groceriesWindow() -> FakeNoteWindow {
        let w = FakeNoteWindow()
        w.set("N-GROCERIES", groceries, checklists: [1: true, 2: false])
        return w
    }

    /// FR-155: a note with checklists is changed in place in Notes' window, never rewritten.
    @Test func appendsToANoteWithChecklistsInItsWindow() async throws {
        let w = groceriesWindow()
        let (fake, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-GROCERIES"), "mode": .string("append"), "text": .string("Ask about oat milk")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(w.text("N-GROCERIES") == groceries.dropLast() + "\nAsk about oat milk\n")
        #expect(!fake.calls.contains { $0.script == NotesCapability.Script.setBody }, "no rewrite")
        #expect(!fake.calls.contains { $0.script == NotesCapability.Script.append })
        #expect(w.paragraphs("N-GROCERIES")[1].1, "Milk is still a checklist item")
        #expect(w.restored == [["x-coredata://STORE-UUID/ICNote/p99"]], "the owner's note is shown again")
        #expect(result.activity == "Claude added to the note “Groceries”")
    }

    /// FR-156: checklist items Claude writes are real ones, ticked where written ticked.
    @Test func writtenChecklistItemsBecomeRealOnes() async throws {
        let w = groceriesWindow()
        let (_, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object([
                "id": .string("N-GROCERIES"), "mode": .string("append"),
                "text": .string("- [ ] Eggs\nThen:\n- [x] Butter"),
            ]))
        #expect(!result.isError, "\(result.content.jsonText)")
        let p = w.paragraphs("N-GROCERIES")
        #expect(p[4].0 == "Eggs" && p[4].1 && !p[4].2)
        #expect(p[5].0 == "Then:" && !p[5].1, "a plain line isn't a checklist item")
        #expect(p[6].0 == "Butter" && p[6].1 && p[6].2, "ticked")
        #expect(w.marked.count == 1)
    }

    @Test func editsAPassageInPlace() async throws {
        let w = groceriesWindow()
        let (_, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object([
                "id": .string("N-GROCERIES"), "mode": .string("edit"), "find": .string("Bread"),
                "text": .string("Rye bread"),
            ]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(w.text("N-GROCERIES") == "Groceries\nMilk\nRye bread\nShop on Saturday\n")
        #expect(w.paragraphs("N-GROCERIES")[2].1, "still a checklist item")
        #expect(w.toggles.isEmpty)
    }

    @Test func renamesANoteWithChecklists() async throws {
        let w = groceriesWindow()
        let (_, tools) = try setup(w)
        let result = await tools["notes_rename"]!.handler(
            .object(["id": .string("N-GROCERIES"), "title": .string("Shopping")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(w.text("N-GROCERIES").hasPrefix("Shopping\nMilk\n"))
    }

    /// FR-157: ticking and unticking, with Notes' database telling what's ticked already.
    @Test func ticksAndUnticksAnItem() async throws {
        let w = groceriesWindow()
        let (_, tools) = try setup(w)
        let tick = await tools["notes_check"]!.handler(
            .object(["id": .string("N-GROCERIES"), "find": .string("Bread"), "checked": .bool(true)]))
        #expect(!tick.isError, "\(tick.content.jsonText)")
        #expect(w.marked == [15])
        #expect(tick.activity == "Claude ticked “Bread” in the note “Groceries”")
        let already = await tools["notes_check"]!.handler(
            .object(["id": .string("N-GROCERIES"), "find": .string("Milk"), "checked": .bool(true)]))
        #expect(!already.isError)
        #expect(already.content.jsonText.contains("already ticked"))
        #expect(w.marked == [15], "nothing pressed")
        let untick = await tools["notes_check"]!.handler(
            .object(["id": .string("N-GROCERIES"), "find": .string("Milk"), "checked": .bool(false)]))
        #expect(!untick.isError)
        #expect(w.marked == [15, 10])
        let plain = await tools["notes_check"]!.handler(
            .object(["id": .string("N-GROCERIES"), "find": .string("Saturday"), "checked": .bool(true)]))
        #expect(plain.isError)
        #expect(plain.content.jsonText.contains("no checklist item"))
    }

    /// FR-156 for new notes: written as ☐ lines, then made real in the window.
    @Test func aNewNoteGetsRealChecklists() async throws {
        let w = FakeNoteWindow()
        let (fake, tools) = try setup(w)
        fake.answer = { _, _ in
            w.set("N-IDEAS", "Ideas\n☐ soil\n☑ seeds\n")
            return "x-coredata://STORE-UUID/ICNote/p14"
        }
        let result = await tools["notes_create"]!.handler(
            .object(["title": .string("Ideas"), "text": .string("- [ ] soil\n- [x] seeds")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(fake.calls.first?.args.first == "<div><h1>Ideas</h1></div><ul><li>☐ soil</li><li>☑ seeds</li></ul>")
        let p = w.paragraphs("N-IDEAS")
        #expect(p[1].0 == "soil" && p[1].1 && !p[1].2)
        #expect(p[2].0 == "seeds" && p[2].1 && p[2].2)
    }

    /// A plain note keeps the AppleScript route (headings and lists keep their style).
    @Test func aPlainNoteIsStillChangedWithAppleScript() async throws {
        let w = FakeNoteWindow()
        let (fake, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-IDEAS"), "mode": .string("append"), "text": .string("## Later")]))
        #expect(!result.isError)
        #expect(fake.lastArgs == ["x-coredata://STORE-UUID/ICNote/p14", "<div><h2>Later</h2></div>"])
        #expect(w.shown.isEmpty, "no window needed")
    }

    /// FR-158: when the window can't show the note, nothing changes and Claude is told why.
    @Test func noWindowMeansNoChange() async throws {
        let w = groceriesWindow()
        w.available = false
        let (_, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-GROCERIES"), "mode": .string("append"), "text": .string("eggs")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("Notes' window"), "\(result.content.jsonText)")
        #expect(w.text("N-GROCERIES") == groceries)
        #expect(w.restored.count == 1, "the owner's note is shown again even so")
    }

    /// A locked Mac has no note editor in Notes' window (checked live 2026-11-04: the window is
    /// there, its editor isn't), so Latchkey says so at once instead of waiting it out.
    @Test func aLockedMacIsAnsweredAtOnce() async throws {
        let w = groceriesWindow()
        w.locked = true
        let (_, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-GROCERIES"), "mode": .string("append"), "text": .string("eggs")]))
        #expect(result.isError)
        #expect(result.content.jsonText.contains("locked"), "\(result.content.jsonText)")
        #expect(w.shown.isEmpty, "Notes wasn't asked to show anything")
        #expect(w.text("N-GROCERIES") == groceries)
    }

    @Test func aNewNoteWithoutTheWindowKeepsItsBoxes() async throws {
        let w = FakeNoteWindow()
        w.available = false
        let (fake, tools) = try setup(w)
        fake.answer = { _, _ in "x-coredata://STORE-UUID/ICNote/p14" }
        let result = await tools["notes_create"]!.handler(
            .object(["title": .string("Ideas"), "text": .string("- [ ] soil")]))
        #expect(!result.isError, "the note was made")
        #expect(result.content.jsonText.contains("☐"), "\(result.content.jsonText)")
    }

    @Test func lockedNotesAndReplacingImagesAreRefused() async throws {
        let w = FakeNoteWindow()
        let (fake, tools) = try setup(w)
        let locked = await tools["notes_update"]!.handler(
            .object(["id": .string("N-SECRET"), "mode": .string("append"), "text": .string("x")]))
        #expect(locked.isError)
        #expect(locked.content.jsonText.contains("locked"))
        let images = await tools["notes_update"]!.handler(
            .object(["id": .string("N-LISBON"), "mode": .string("replace"), "text": .string("x")]))
        #expect(images.isError)
        #expect(images.content.jsonText.contains("images"), "\(images.content.jsonText)")
        #expect(fake.calls.isEmpty)
        #expect(w.shown.isEmpty)
    }

    @Test func aChangeNotesHasntSavedIsSaidSo() async throws {
        let w = groceriesWindow()
        w.saved = false
        let (_, tools) = try setup(w)
        let result = await tools["notes_update"]!.handler(
            .object(["id": .string("N-GROCERIES"), "mode": .string("append"), "text": .string("eggs")]))
        #expect(result.content.jsonText.contains("hasn't saved"), "\(result.content.jsonText)")
    }

    @Test func theChangeToolReachesCheck() async throws {
        let w = groceriesWindow()
        let store = try NotesStore(url: NotesFixture.make())
        let change = try #require(
            NotesCapability.writeTools(store: { store }, scripts: FakeScripts(), window: w.window).first)
        let result = await change.handler(
            .object(["action": .string("check"), "id": .string("N-GROCERIES"), "find": .string("Bread")]))
        #expect(!result.isError, "\(result.content.jsonText)")
        let untick = await change.handler(
            .object(["action": .string("uncheck"), "id": .string("N-GROCERIES"), "find": .string("Milk")]))
        #expect(!untick.isError)
        #expect(w.marked.count == 2)
    }
}
