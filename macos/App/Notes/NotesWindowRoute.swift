import Foundation

/// Changes made in Notes' window (spec 002 plan D3a): one at a time, the owner's note shown
/// again after, "changed" only once Notes has saved.
extension NotesCapability {
    static let windowQueue = WindowQueue()

    /// Runs changes one after another: the window is shared. Waits rather than refuses.
    actor WindowQueue {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
            if busy { await withCheckedContinuation { waiting.append($0) } }
            busy = true
            defer {
                if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
            }
            return try await work()
        }
    }

    struct WindowFailure: Error {
        var message: String

        /// Window editing is switched off (NoteWindow.enabled).
        static let off = WindowFailure(message: "real checklists aren't available yet; that is being fixed.")

        static let locked = WindowFailure(
            message:
                "The Mac is locked. Notes lets Latchkey change notes with checklists, links, or images only through its window, and macOS doesn't show a note there while the Mac is locked. Nothing was changed; it works again once someone unlocks the Mac. Plain notes can still be changed, and new notes made."
        )

        /// Why ☐/☑ stayed, for an answer whose change itself did happen.
        var boxes: String {
            " Its checklist items are ☐ and ☑ characters for now: "
                + (message == Self.locked.message
                    ? "the Mac is locked, and Notes makes real checklists only in its window. Ask again once the Mac is unlocked."
                    : message)
        }

        static let unavailable = WindowFailure(
            message:
                "Notes' window couldn't show the note: Notes may be hidden or minimized, the Mac may be locked or asleep, or Latchkey may not be allowed to use Accessibility (Latchkey's Settings → Permissions)."
        )
    }

    /// Shows the note, runs `work` with its editor's text, then shows the owner's note again.
    static func inWindow<T: Sendable>(
        scriptID: String, noteID: String, window: NoteWindow,
        ready: @escaping @Sendable (String) -> Bool = { _ in true },
        _ work: @Sendable (String) async throws -> T
    ) async throws -> T {
        if window.locked() { throw WindowFailure.locked }
        return try await windowQueue.run {
            let previous = try await window.show(scriptID).filter { $0 != scriptID }
            do {
                guard let text = await window.open(noteID, ready) else { throw WindowFailure.unavailable }
                let out = try await work(text)
                await window.restore(previous)
                return out
            } catch {
                await window.restore(previous)
                throw error
            }
        }
    }

    /// Makes the change, then turns the ☐/☑ lines it wrote into real checklist items.
    static func apply(_ plan: NoteEditPlan, to text: String, noteID: String, window: NoteWindow, checklists: Bool)
        async throws
    {
        guard window.replace(noteID, plan.range, plan.text) else {
            throw WindowFailure(message: "Notes' window didn't take the text; nothing was changed.")
        }
        guard checklists else { return }
        let changed = (text as NSString).replacingCharacters(in: plan.range, with: plan.text)
        try await makeChecklists(changed, region: plan.region, noteID: noteID, window: window)
    }

    /// FR-156: each paragraph in the region is a checklist item exactly when it starts with ☐ or
    /// ☑ (the mark is removed); ☑ items are ticked.
    static func makeChecklists(_ text: String, region: NSRange, noteID: String, window: NoteWindow) async throws {
        // 1. The ☐/☑ marks come out, in the background.
        var removed = 0
        var changes: [ParagraphFormat] = []
        for line in NoteWindowEdit.lines(in: text, region: region) {
            let at = line.at - removed
            if line.mark != nil {
                guard window.replace(noteID, NSRange(location: at, length: 2), "") else {
                    throw WindowFailure(message: "Notes' window didn't take a checklist item.")
                }
                removed += 2
            }
            changes.append(ParagraphFormat(at: at, checklist: line.mark != nil, tick: line.mark == .ticked))
        }
        // 2. Each written paragraph becomes a checklist item or stays plain, and ticks are set,
        // in one moment with Notes in front.
        guard await window.format(noteID, changes) else {
            throw WindowFailure(message: "Notes' Format menu didn't answer, so the checklist items may be plain lines.")
        }
        // 3. Read back: every paragraph must be what was asked.
        guard let states = await window.checklistStates(noteID, changes.map(\.at)) else {
            throw WindowFailure(message: "Latchkey couldn't read back the checklist items.")
        }
        let wrong = zip(changes, states).filter { $0.0.checklist != $0.1 }.count
        if wrong > 0 {
            throw WindowFailure(
                message:
                    "Notes shows \(wrong) of the written lines differently from what was asked (checklist item or plain line)."
            )
        }
    }

    /// Whether written text has checklist items (they need the window to become real ones).
    static func hasChecklistItems(_ text: String) -> Bool {
        NoteWindowEdit.display(text).split(separator: "\n").contains { $0.hasPrefix("☐ ") || $0.hasPrefix("☑ ") }
    }

    /// The last non-empty line written, as the editor shows it: when it's there, the editor has
    /// the text AppleScript just wrote.
    static func lastShownLine(_ written: String) -> String {
        NoteWindowEdit.display(written).split(separator: "\n").last.map(String.init) ?? ""
    }

    /// FR-159: the answer's ending, once Notes' database shows the change (or doesn't yet).
    static func savedNote(_ window: NoteWindow, _ check: @escaping @Sendable () async -> Bool) async -> String {
        await window.saved(check)
            ? "" : " Notes shows the change but hasn't saved it yet; check with notes_read in a moment."
    }
}
