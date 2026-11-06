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

    static let live = RemindersWindow(
        show: { id in
            // Reminders' own link to a reminder opens it in the main window, selected.
            guard let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(id)"),
                let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Live.bundleID)
            else { return false }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
            for _ in 0..<50 {
                if Live.selectedRow() != nil { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        },
        rows: { Live.rows().map(\.row) },
        act: { action in
            guard let row = Live.selectedRow() else { return false }
            var names: CFArray?
            guard AXUIElementCopyActionNames(row, &names) == .success, let all = names as? [String],
                let name = all.first(where: { Live.actionName($0) == action.rawValue })
            else { return false }
            return AXUIElementPerformAction(row, name as CFString) == .success
        },
        retitle: { text in
            guard let row = Live.selectedRow(), let field = Live.titleField(row) else { return false }
            let old = AppWindowReader.string(field, kAXValueAttribute) ?? ""
            var range = CFRange(location: 0, length: (old as NSString).length)
            guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                let value = AXValueCreate(.cfRange, &range),
                AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success,
                AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            else { return false }
            return AXUIElementPerformAction(field, "AXConfirm" as CFString) == .success
        },
        title: {
            Live.selectedRow().flatMap(Live.titleField).flatMap { AppWindowReader.string($0, kAXValueAttribute) }
        },
        menu: { path in
            guard let app = Live.runningApp() else { return false }
            let previous = NSWorkspace.shared.frontmostApplication
            app.activate()
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(for: .milliseconds(50))
            }
            var done = false
            // The menu updates for the selection a moment after Reminders comes forward.
            for _ in 0..<20 {
                if let item = Live.menuItem(path), AppWindowReader.string(item, kAXEnabledAttribute) == "1" {
                    done = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let previous, previous != app { previous.activate() }
            return done
        },
        menuItems: { path in
            guard let menu = Live.menuItem(path) else { return [] }
            return Live.children(menu).flatMap(Live.children).compactMap {
                AppWindowReader.string($0, kAXTitleAttribute)
            }
        },
        locked: { SystemScreen().isLocked() },
        saved: { check in
            for _ in 0..<25 {
                if check() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        })

    enum Live {
        static let bundleID = "com.apple.reminders"

        static func runningApp() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }

        static func application() -> AXUIElement? {
            guard let pid = runningApp()?.processIdentifier else { return nil }
            let app = AXUIElementCreateApplication(pid)
            // A busy or locked Reminders answers slowly; never wait long on one question.
            AXUIElementSetMessagingTimeout(app, 2)
            return app
        }

        static func children(_ e: AXUIElement) -> [AXUIElement] {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
            return (v as? [AXUIElement]) ?? []
        }

        /// A custom action's name: Accessibility gives "Name:Indent\nTarget:…\nSelector:…".
        static func actionName(_ raw: String) -> String {
            let first = raw.split(separator: "\n").first.map(String.init) ?? raw
            return first.hasPrefix("Name:") ? String(first.dropFirst(5)) : first
        }

        /// The list of reminders: the outline beside the sidebar, inside the window's layout area.
        static func outline() -> AXUIElement? {
            guard let app = application() else { return nil }
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
                let windows = v as? [AXUIElement]
            else { return nil }
            for w in windows where AppWindowReader.string(w, kAXRoleAttribute) == "AXWindow" {
                for split in children(w) where AppWindowReader.string(split, kAXRoleAttribute) == "AXSplitGroup" {
                    for area in children(split) where AppWindowReader.string(area, kAXRoleAttribute) == "AXLayoutArea" {
                        for scroll in children(area) {
                            for o in children(scroll) where AppWindowReader.string(o, kAXRoleAttribute) == "AXOutline" {
                                return o
                            }
                        }
                    }
                }
            }
            return nil
        }

        /// The rows that are reminders (they have a title field), with their elements.
        static func rows() -> [(element: AXUIElement, row: ReminderRow)] {
            guard let outline = outline() else { return [] }
            return children(outline).compactMap { r in
                guard AppWindowReader.string(r, kAXRoleAttribute) == "AXRow", let field = titleField(r) else {
                    return nil
                }
                let level = Int(AppWindowReader.string(r, "AXDisclosureLevel") ?? "1") ?? 1
                return (
                    r,
                    ReminderRow(
                        title: AppWindowReader.string(field, kAXValueAttribute) ?? "", level: max(0, level - 1),
                        selected: AppWindowReader.string(r, kAXSelectedAttribute) == "1")
                )
            }
        }

        static func selectedRow() -> AXUIElement? { rows().first { $0.row.selected }?.element }

        /// The row's title: the text field in its cell.
        static func titleField(_ row: AXUIElement) -> AXUIElement? {
            for cell in children(row) {
                for group in children(cell) {
                    if let f = children(group).first(where: {
                        AppWindowReader.string($0, kAXRoleAttribute) == "AXTextField"
                    }) {
                        return f
                    }
                }
            }
            return nil
        }

        /// A menu item by the titles on its path from the menu bar.
        static func menuItem(_ path: [String]) -> AXUIElement? {
            guard let app = application(), !path.isEmpty else { return nil }
            var bar: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
                CFGetTypeID(bar) == AXUIElementGetTypeID()
            else { return nil }
            var level = [bar as! AXUIElement]
            var found: AXUIElement?
            for title in path {
                found = level.flatMap { [$0] + children($0) }.flatMap { [$0] + children($0) }.first {
                    AppWindowReader.string($0, kAXTitleAttribute) == title
                }
                guard let found else { return nil }
                level = [found]
            }
            return found
        }
    }
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
