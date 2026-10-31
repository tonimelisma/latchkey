import CoreGraphics
import Foundation

/// macOS asks again, about once a month, whether an app may keep capturing the screen ("continue
/// to allow"), at the app's first screenshot after the date it set. Latchkey takes a throwaway
/// screenshot as soon as one is due while the Owner is at the Mac, so the question comes then and
/// not while Claude uses the Mac unattended (FR-624, plan D21).
enum ScreenReminder {
    /// macOS's own record of these reminders, readable with Full Disk Access.
    static let approvals = URL.homeDirectory.appending(
        path: "Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
    /// The Owner counts as at the Mac when the keyboard or pointer moved this recently.
    static let presentWithin: TimeInterval = 60
    /// After a throwaway screenshot, the next try waits this long (the question may be waiting).
    static let retryAfter: TimeInterval = 3600

    /// When macOS will next ask about `bundleID`; nil when the record has no such entry.
    static func due(in data: Data, bundleID: String) -> Date? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entry = plist[bundleID] as? [String: Any]
        else { return nil }
        return entry["kScreenCapturePrivacyHintDate"] as? Date
    }

    static func shouldAsk(due: Date?, now: Date, idle: TimeInterval, locked: Bool, lastTry: Date?) -> Bool {
        guard let due, now >= due, !locked, idle < presentWithin else { return false }
        if let lastTry, now.timeIntervalSince(lastTry) < retryAfter { return false }
        return true
    }

    /// Reads the record and the Owner's presence; nil means nothing to do.
    static func dueNow(lastTry: Date?, now: Date = Date()) -> Date? {
        guard let id = Bundle.main.bundleIdentifier, let data = try? Data(contentsOf: approvals),
            let due = due(in: data, bundleID: id)
        else { return nil }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)  // any input
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return shouldAsk(due: due, now: now, idle: idle, locked: locked, lastTry: lastTry) ? due : nil
    }
}
