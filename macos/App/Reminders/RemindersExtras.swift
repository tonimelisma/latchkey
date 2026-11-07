import Foundation

/// The changes EventKit can't make: flag, tags, parent, section (spec 007 FR-715 to FR-719).
/// Reads flags, tags, subtasks, and sections from Reminders' database (spec 007 plan D7). They
/// aren't changed: that needed the Reminders app's window, withdrawn on 2026-11-07 (Toni: Latchkey
/// never drives an app the user may be using).
struct RemindersExtras: Sendable {
    var source: any RemindersExtrasSource

    static let none = RemindersExtras(source: NoRemindersExtras())
    static let live = RemindersExtras(source: RemindersStore(root: RemindersStore.defaultRoot))

    /// Whether `id` is a subtask or has subtasks: moving it to another list would lose that (macOS
    /// drops the links when a reminder changes lists).
    func hasFamily(_ id: String, _ snap: RemindersSnapshot) -> Bool {
        let e = snap.extra(id)
        return e.parentID != nil || !e.subtaskIDs.isEmpty
    }

    static func tagText(_ tags: [String]) -> String { tags.map { "#" + $0 }.joined(separator: " ") }
}
