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
    /// Every app Latchkey scripts, asked for in setup whatever the levels (Toni, 2026-10-31).
    static let scriptedApps = [notesApp, messagesApp, mailApp, safariApp]

    enum Automation: Sendable, Equatable { case allowed, denied, notAsked }

    /// Whether Latchkey may control the app (Automation). Nil when it can't be known (the app
    /// isn't running). macOS's answer blocks its thread, for as long as the Owner takes to answer
    /// and, on a busy Mac, for many seconds even without a question: so it waits on a thread of
    /// its own, never one of Swift's shared ones. Run from Swift's pool (as until 0.8.108), the
    /// test host's setup windows held all 8 of them at once and every other task in the process
    /// stopped: shell jobs weren't seen ending, WebKit pages didn't load (2026-11-03).
    nonisolated static func automation(of bundleID: String, ask: Bool) async -> Automation? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: blockingAutomation(bundleID, ask)) }
        }
    }

    private nonisolated static func blockingAutomation(_ bundleID: String, _ ask: Bool) -> Automation? {
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

    /// Like `automation(of:ask: false)`, but an app that isn't running is opened hidden first, as
    /// its script would open it anyway, and looked at for up to 5 seconds (spec 001 FR-625).
    nonisolated static func automationOpening(_ bundleID: String) async -> Automation? {
        if let known = await automation(of: bundleID, ask: false) { return known }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<20 {
            if let known = await automation(of: bundleID, ask: false) { return known }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
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

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
            // Asked in setup, never here: a question during use waits on an unattended Mac.
            let center = UNUserNotificationCenter.current()
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
    var notifications: NotificationAccess = .notAsked
    /// Nil until Latchkey has looked.
    var localNetwork: Bool?
    /// A screenshot has gone through since Screen Recording was allowed (macOS's second question).
    var screenAccess = false
}

/// Whether Latchkey may post notifications; unknown until macOS has said.
enum NotificationAccess: Sendable, Equatable { case allowed, denied, notAsked, unknown }

/// One macOS approval Latchkey uses, in the Settings window's Permissions tab (FR-606). Every
/// one is asked for at first run, whatever each capability's level, so no macOS question waits
/// on an unattended Mac later (FR-623, Toni 2026-10-31).
struct Approval: Identifiable, Equatable {
    enum State: Equatable {
        case allowed
        /// Not allowed; setup asks for it.
        case missing
        /// macOS hasn't said yet (just after launch); never counts as missing.
        case checking
    }

    let id: String
    let title: String
    let purpose: String
    let state: State

    static func list(_ f: ApprovalFacts) -> [Approval] {
        func state(_ allowed: Bool) -> State { allowed ? .allowed : .missing }
        return [
            Approval(
                id: "helper", title: "Keep This Mac Awake",
                purpose: "So Claude can reach this Mac with the lid closed.", state: state(f.helper)),
            Approval(
                id: "disk", title: "Full Disk Access", purpose: "To read your files, notes, messages, and mail.",
                state: state(f.fullDiskAccess)),
            Approval(
                id: "notifications", title: "Notifications", purpose: "To tell you what Claude did on this Mac.",
                state: f.notifications == .unknown ? .checking : state(f.notifications == .allowed)),
            Approval(
                id: "notes", title: "Control Notes", purpose: "To create, edit, and delete notes.",
                state: state(f.notes == .allowed)),
            Approval(
                id: "messages", title: "Control Messages", purpose: "To send messages for you.",
                state: state(f.messages == .allowed)),
            Approval(
                id: "mail", title: "Control Mail", purpose: "To organise and send email for you.",
                state: state(f.mail == .allowed)),
            Approval(
                id: "contacts", title: "Contacts",
                purpose: "To look up, add, and change contacts, and show names in messages.",
                state: state(f.contacts == .authorized)),
            Approval(
                id: "calendars", title: "Calendars", purpose: "To see your events and add or change them.",
                state: state(f.calendars)),
            Approval(
                id: "reminders", title: "Reminders", purpose: "To see your reminders and add or change them.",
                state: state(f.reminders)),
            Approval(
                id: "location", title: "Location",
                purpose: f.location == .servicesOff
                    ? "To tell Claude where this Mac is. Location Services are off for the whole Mac."
                    : "To tell Claude where this Mac is, and find places nearby.",
                state: f.location == .unknown ? .checking : state(f.location == .allowed)),
            Approval(
                id: "localNetwork", title: "Local Network",
                purpose: "So commands Claude runs can reach printers, routers, and other devices on your network.",
                state: f.localNetwork == nil ? .checking : state(f.localNetwork == true)),
            Approval(
                id: "safari", title: "Control Safari", purpose: "To open and read web pages, signed in as you.",
                state: state(f.safari == .allowed)),
            Approval(
                id: "safariJS", title: "Safari JavaScript",
                purpose:
                    "In Safari’s Developer settings, turn on “Allow JavaScript from Apple Events”, then click Check.",
                state: state(f.safariJavaScript == true)),
            Approval(
                id: "screen", title: "Screen & System Audio Recording",
                purpose: "To see the screen, for computer control.", state: state(f.screenRecording)),
            Approval(
                id: "screenAccess", title: "Direct Screen Access",
                purpose: "macOS asks once more, at the first screenshot. Allow it here, not while you’re away.",
                state: state(f.screenRecording && f.screenAccess)),
            Approval(
                id: "accessibility", title: "Accessibility",
                purpose: "To use the mouse and keyboard, and to write email in Mail’s window.",
                state: state(f.accessibility)),
        ]
    }
}
