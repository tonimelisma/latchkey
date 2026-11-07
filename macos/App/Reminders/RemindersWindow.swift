import AppKit
import ApplicationServices

/// A reminder's row in the Reminders window, as Accessibility shows it.
struct ReminderRow: Sendable, Equatable {
    var title: String
    /// 0 for a reminder, 1 for a subtask.
    var level: Int
    var selected = false
}

/// The Reminders app's own window, driven through Accessibility in the background (spec 007
/// plan D7, FR-715 to FR-719). Subtasks, tags, flags, and sections have no public API: EventKit
/// has none and the Reminders AppleScript dictionary only flags reminders that aren't subtasks.
/// Each closure acts on the reminder `show` selected.
struct RemindersWindow: Sendable {
    /// Selects the reminder in Reminders' window without bringing Reminders forward.
    var show: @Sendable (_ id: String) async -> Bool
    /// The rows of the list shown, top to bottom.
    var rows: @Sendable () -> [ReminderRow]
    /// One of the row's own actions (Indent, Outdent, Move Up, Move Down) on the selected row.
    var act: @Sendable (_ action: RowAction) -> Bool
    /// Replaces the selected row's title text as typing would (so "#tag" becomes a tag).
    var retitle: @Sendable (_ text: String) -> Bool
    /// The selected row's title text.
    var title: @Sendable () -> String?
    /// A menu item for the selected row, by its path; Reminders comes forward for a moment
    /// (its menus do nothing while another app is in front).
    var menu: @Sendable (_ path: [String]) async -> Bool
    /// The titles of a menu's items (e.g. File → Move to Section).
    var menuItems: @Sendable (_ path: [String]) -> [String]
    /// Whether the Mac is locked: Reminders' window then has no rows (checked live 2026-11-05).
    var locked: @Sendable () -> Bool
    /// Waits until `check` sees the change in Reminders' database.
    var saved: @Sendable (_ check: @escaping @Sendable () -> Bool) async -> Bool

    enum RowAction: String, Sendable {
        case indent = "Indent", outdent = "Outdent", moveUp = "Move Up", moveDown = "Move Down"
    }

    /// No window: what tests of the plain tools get.
    static let unavailable = RemindersWindow(
        show: { _ in false }, rows: { [] }, act: { _ in false }, retitle: { _ in false }, title: { nil },
        menu: { _ in false }, menuItems: { _ in [] }, locked: { false }, saved: { _ in false })
}

/// Where a reminder must go in the list so that Indent makes it a subtask of `parent`: Indent
/// puts a row under the nearest reminder above it (spec 007 plan D7). Pure, so it's tested
/// without Reminders.
enum ReminderRowPlan {
    enum Step: Equatable {
        case outdent, moveUp, moveDown, indent, done
        case parentNotShown
    }

    /// The next step for the selected row to end up under the row titled `parent`.
    static func next(_ rows: [ReminderRow], parent: String) -> Step {
        guard let me = rows.firstIndex(where: \.selected) else { return .parentNotShown }
        // The nearest reminder (not subtask) above the selected row, other than itself.
        let above = rows[..<me].lastIndex { $0.level == 0 }
        if rows[me].level == 1 {
            if let above, rows[above].title == parent { return .done }
            return .outdent
        }
        let parents = rows.indices.filter { $0 != me && rows[$0].level == 0 && rows[$0].title == parent }
        guard let target = parents.min(by: { abs($0 - me) < abs($1 - me) }) else { return .parentNotShown }
        if let above, above == target { return .indent }
        return target < me ? .moveUp : .moveDown
    }
}
