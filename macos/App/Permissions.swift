import AppKit
import CoreServices
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

    static let notesApp = "com.apple.Notes"
    static let messagesApp = "com.apple.MobileSMS"
    static let safariApp = "com.apple.Safari"

    enum Automation: Sendable, Equatable { case allowed, denied, notAsked }

    /// Whether Latchkey may control the app (Automation). Blocks while macOS asks the Owner, so
    /// call it off the main thread. Nil when it can't be known (the app isn't running).
    nonisolated static func automation(of bundleID: String, ask: Bool) -> Automation? {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return nil
        }
    }

    static func open(app bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Opens a page of System Settings → Privacy & Security, like "Privacy_Accessibility".
    static func openPrivacySettings(_ page: String) {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(page)"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    static func openContactsSettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    static func openAutomationSettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
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
