import AppKit
import Contacts
import CoreServices
import Foundation
import UserNotifications

/// macOS permissions Notes and Messages need (spec 002 FR-140, plan D5).
enum Permissions {
    static let notesDatabase = URL.homeDirectory.appending(
        path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    static let messagesDatabase = URL.homeDirectory.appending(path: "Library/Messages/chat.db")
    /// Mail's index (spec 008), in its newest data folder; nil when it can't be found (or listed).
    static var mailIndex: URL? { MailStore.defaultRoot().map(MailStore.indexURL) }

    /// Full Disk Access can't be asked for; the only test is to open a protected file. A missing
    /// file (Messages never used) doesn't count against it.
    static var hasFullDiskAccess: Bool {
        let existing = ([notesDatabase, messagesDatabase] + [mailIndex].compactMap { $0 }).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existing.isEmpty else { return true }
        return existing.allSatisfy { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            try? handle.close()
            return true
        }
    }

    static let notesApp = "com.apple.Notes"
    static let messagesApp = "com.apple.MobileSMS"
    static let mailApp = MailCapability.mailApp
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

/// A setup step: done, certainly not done, or not known yet because macOS hasn't said (FR-621).
enum SetupStep: Sendable, Equatable { case done, missing, unknown }

/// Whether setup is finished, deciding only on what macOS has said: a step not known yet never
/// opens the setup window (2026-10-27: it opened over a finished setup when Location read "not
/// asked" for a moment at launch).
enum SetupDecision {
    static func missing(_ steps: [(String, SetupStep)]) -> [String] { steps.filter { $0.1 == .missing }.map(\.0) }
    static func unknown(_ steps: [(String, SetupStep)]) -> [String] { steps.filter { $0.1 == .unknown }.map(\.0) }
    static func settled(_ steps: [(String, SetupStep)]) -> Bool { unknown(steps).isEmpty }
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

/// What macOS has allowed, from the app's own checks, for the list of approvals (FR-606).
struct ApprovalFacts {
    var helper: Bool
    var fullDiskAccess: Bool
    var notes: Permissions.Automation
    var messages: Permissions.Automation
    var mail: Permissions.Automation = .notAsked
    var safari: Permissions.Automation
    var contacts: CNAuthorizationStatus
    var calendars = false
    var reminders = false
    var location = LocationAccess.notAsked
    var safariJavaScript: Bool?
    var screenRecording: Bool
    var accessibility: Bool
    var level: (String) -> AccessLevel
}

/// One macOS approval Latchkey uses, in the Settings window's Permissions tab (FR-606).
struct Approval: Identifiable, Equatable {
    enum State: Equatable {
        case allowed
        /// The current levels need it and it isn't allowed; setup asks for it too.
        case missing
        /// Not allowed, and nothing turned on needs it.
        case notNeeded
        /// Not allowed and not required: Messages shows numbers instead of names.
        case optional
        /// macOS hasn't said yet (just after launch); never counts as missing.
        case checking
    }

    let id: String
    let title: String
    let purpose: String
    let state: State

    static func list(_ f: ApprovalFacts) -> [Approval] {
        let notes = f.level(CapabilityRegistry.notes)
        let messages = f.level(CapabilityRegistry.messages)
        let mail = f.level(CapabilityRegistry.mail)
        let browser = f.level(CapabilityRegistry.browser) != .off
        let computer = f.level(CapabilityRegistry.computer) != .off
        let anyOn = CapabilityRegistry.all.contains { f.level($0) != .off }
        func state(_ allowed: Bool, needed: Bool) -> State { allowed ? .allowed : needed ? .missing : .notNeeded }
        // The Contacts capability needs it; Messages only uses it for names (spec 007 FR-745).
        let contacts: State =
            switch (f.contacts, f.level(CapabilityRegistry.contacts) != .off, messages != .off) {
            case (.authorized, _, _): .allowed
            case (_, true, _): .missing
            case (_, false, false): .notNeeded
            case (.notDetermined, false, true): .missing
            default: .optional
            }
        let contactsPurpose =
            f.level(CapabilityRegistry.contacts) != .off
            ? "To look up, add, and change contacts, and show names in messages."
            : "To show names in messages instead of phone numbers. Optional."
        return [
            Approval(
                id: "helper", title: "Keep This Mac Awake",
                purpose: "So Claude can reach this Mac with the lid closed.", state: state(f.helper, needed: true)),
            Approval(
                id: "disk", title: "Full Disk Access", purpose: "To read your files, notes, messages, and mail.",
                state: state(f.fullDiskAccess, needed: anyOn)),
            Approval(
                id: "notes", title: "Control Notes", purpose: "To create, edit, and delete notes.",
                state: state(f.notes == .allowed, needed: notes == .readWrite)),
            Approval(
                id: "messages", title: "Control Messages", purpose: "To send messages for you.",
                state: state(f.messages == .allowed, needed: messages == .readWrite)),
            Approval(
                id: "mail", title: "Control Mail", purpose: "To organise and send email for you.",
                state: state(f.mail == .allowed, needed: mail == .readWrite)),
            Approval(id: "contacts", title: "Contacts", purpose: contactsPurpose, state: contacts),
            Approval(
                id: "calendars", title: "Calendars", purpose: "To see your events and add or change them.",
                state: state(f.calendars, needed: f.level(CapabilityRegistry.calendar) != .off)),
            Approval(
                id: "reminders", title: "Reminders", purpose: "To see your reminders and add or change them.",
                state: state(f.reminders, needed: f.level(CapabilityRegistry.reminders) != .off)),
            Approval(
                id: "location", title: "Location",
                purpose: f.location == .servicesOff
                    ? "To tell Claude where this Mac is. Location Services are off for the whole Mac."
                    : "To tell Claude where this Mac is, and find places nearby.",
                state: f.location == .unknown
                    ? .checking : state(f.location == .allowed, needed: f.level(CapabilityRegistry.location) != .off)),
            Approval(
                id: "safari", title: "Control Safari", purpose: "To open and read web pages, signed in as you.",
                state: state(f.safari == .allowed, needed: browser)),
            Approval(
                id: "safariJS", title: "Safari JavaScript",
                purpose:
                    "In Safari’s Developer settings, turn on “Allow JavaScript from Apple Events”, then click Check.",
                state: state(f.safariJavaScript == true, needed: browser)),
            Approval(
                id: "screen", title: "Screen & System Audio Recording",
                purpose: "To see the screen, for computer control.",
                state: state(f.screenRecording, needed: computer)),
            Approval(
                id: "accessibility", title: "Accessibility",
                purpose: "To use the mouse and keyboard, for computer control.",
                state: state(f.accessibility, needed: computer)),
        ]
    }
}
