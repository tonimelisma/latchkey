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
        try await windowQueue.run {
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
        var removed = 0
        var ticks: [Int] = []
        for line in NoteWindowEdit.lines(in: text, region: region) {
            let at = line.at - removed
            if line.mark != nil {
                guard window.replace(noteID, NSRange(location: at, length: 2), "") else {
                    throw WindowFailure(message: "Notes' window didn't take a checklist item.")
                }
                removed += 2
            }
            guard let isChecklist = window.isChecklist(noteID, at) else {
                throw WindowFailure(message: "Latchkey couldn't find Notes' Checklist button.")
            }
            if isChecklist != (line.mark != nil) {
                guard window.toggleChecklist(noteID) else {
                    throw WindowFailure(message: "Notes' Checklist button didn't answer.")
                }
            }
            if line.mark == .ticked { ticks.append(at) }
        }
        if !ticks.isEmpty, await !window.markChecked(noteID, ticks) {
            throw WindowFailure(message: "Notes didn't tick the checked items; they are there unticked.")
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
