import Foundation
import Testing

@testable import Latchkey

/// macOS's monthly screen question is brought on while the Owner is at the Mac (FR-624).
struct ScreenReminderTests {
    static let due = Date(timeIntervalSince1970: 1_795_000_000)

    /// The shape macOS 27 writes (seen on Toni's Mac, 2026-10-31).
    static func record(_ id: String, due: Date) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "other.app": ["kScreenCapturePrivacyHintDate": Date.distantPast],
                id: [
                    "kScreenCaptureAlertableUsageCount": 48,
                    "kScreenCaptureApprovalLastAlerted": due.addingTimeInterval(-30 * 86400),
                    "kScreenCaptureApprovalLastUsed": due.addingTimeInterval(-86400),
                    "kScreenCapturePrivacyHintDate": due,
                ],
            ], format: .binary, options: 0)
    }

    @Test func readsTheDueDate() throws {
        let data = try Self.record("net.melisma.latchkey", due: Self.due)
        #expect(ScreenReminder.due(in: data, bundleID: "net.melisma.latchkey") == Self.due)
        #expect(ScreenReminder.due(in: data, bundleID: "net.melisma.latchkey.dev") == nil)
        #expect(ScreenReminder.due(in: Data("not a plist".utf8), bundleID: "net.melisma.latchkey") == nil)
    }

    @Test func asksOnlyWhenDueAndTheOwnerIsHere() {
        let after = Self.due.addingTimeInterval(10)
        func ask(_ now: Date, idle: TimeInterval = 5, locked: Bool = false, lastTry: Date? = nil) -> Bool {
            ScreenReminder.shouldAsk(due: Self.due, now: now, idle: idle, locked: locked, lastTry: lastTry)
        }
        #expect(ask(after))
        #expect(!ask(Self.due.addingTimeInterval(-10)))  // not due yet
        #expect(!ask(after, idle: 600))  // away
        #expect(!ask(after, locked: true))
        #expect(!ask(after, lastTry: after.addingTimeInterval(-60)))  // just tried
        #expect(ask(after, lastTry: after.addingTimeInterval(-7200)))
        #expect(!ScreenReminder.shouldAsk(due: nil, now: after, idle: 0, locked: false, lastTry: nil))
    }
}
