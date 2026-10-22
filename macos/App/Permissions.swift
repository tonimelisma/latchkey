import AppKit
import Foundation
import UserNotifications

/// macOS permissions Notes and Messages need (spec 002 FR-140, plan D5).
enum Permissions {
    static let notesDatabase = URL.homeDirectory.appending(
        path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    static let messagesDatabase = URL.homeDirectory.appending(path: "Library/Messages/chat.db")

    /// Full Disk Access can't be asked for; the only test is to open a protected file. A missing
    /// file (Messages never used) doesn't count against it.
    static var hasFullDiskAccess: Bool {
        let existing = [notesDatabase, messagesDatabase].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return true }
        return existing.allSatisfy { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            try? handle.close()
            return true
        }
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    static func openFullDiskAccessSettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

/// Notifications for changes Claude makes on the Mac (FR-130).
enum Notifier {
    static func post(_ body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = "Claude"
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
