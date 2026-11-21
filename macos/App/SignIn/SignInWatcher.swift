import Foundation
import UserNotifications

/// Spec 013 FR-1304: whether the weekly reminder to export again is due.
enum SignInReminder {
    static let week: TimeInterval = 7 * 86400
    static let category = "signins.export"

    /// `imported`: the last import; `since`: when Sign-in was first seen, for a Mac with none yet;
    /// `reminded`: the last reminder; `on`: the reminder and Sign-in are both on.
    static func due(now: Date, imported: Date?, since: Date, reminded: Date?, on: Bool) -> Bool {
        guard on, now.timeIntervalSince(imported ?? since) >= week else { return false }
        if let reminded, now.timeIntervalSince(reminded) < week { return false }
        return true
    }
}

/// Watches the import folder (plan D2) and posts the weekly reminder (plan D4) while the app runs.
@MainActor
final class SignInWatcher {
    static let shared = SignInWatcher()

    /// The name of the last file taken in, for the one-touch export to know its file arrived.
    private(set) var lastTaken: String?
    /// Told after every import, with what the Owner was told.
    var imported: (SignInImport.Outcome) -> Void = { _ in }
    /// Whether Sign-in is on (no reminders while it is off).
    var signInOn: () -> Bool = { true }
    private var timer: Timer?
    private var lastReminderCheck = Date.distantPast
    private let defaults = UserDefaults.standard

    enum Keys {
        static let reminder = "signInReminder"
        static let firstSeen = "signInFirstSeen"
        static let reminded = "signInLastReminded"
    }

    var reminderOn: Bool {
        get { defaults.object(forKey: Keys.reminder) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.reminder) }
    }

    func start() {
        guard timer == nil else { return }
        try? SignInImport.prepare()
        if defaults.object(forKey: Keys.firstSeen) == nil { defaults.set(Date(), forKey: Keys.firstSeen) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in SignInWatcher.shared.tick() }
        }
        tick()
    }

    private func tick() {
        for outcome in SignInImport.check(taken: { self.lastTaken = $0 }) {
            EventLog.shared.record(
                .app, "Sign-in import: \(outcome)", error: { if case .imported = outcome { false } else { true } }())
            post(title: "Latchkey", body: outcome.told, category: nil)
            imported(outcome)
        }
        let now = Date()
        guard now.timeIntervalSince(lastReminderCheck) >= 3600 else { return }
        lastReminderCheck = now
        let importedAt: Date? = if case .some(let c) = SignInStore.shared.load() { c.imported } else { nil }
        guard
            SignInReminder.due(
                now: now, imported: importedAt, since: defaults.object(forKey: Keys.firstSeen) as? Date ?? now,
                reminded: defaults.object(forKey: Keys.reminded) as? Date, on: reminderOn && signInOn())
        else { return }
        defaults.set(now, forKey: Keys.reminded)
        post(
            title: "Update Latchkey’s sign-ins",
            body: "Click to export your passwords from Passwords to Latchkey again. You’ll only need Touch ID.",
            category: SignInReminder.category)
        EventLog.shared.record(.app, "Sign-in: posted the weekly reminder to export again")
    }

    private func post(title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        // Asked in setup, never here (FR-623).
        Task {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
