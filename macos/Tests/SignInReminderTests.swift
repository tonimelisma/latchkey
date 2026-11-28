import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1304: one notification a week while the copies are a week old or more.
@Suite struct SignInReminderTests {
    static let day: TimeInterval = 86400
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dueAWeekAfterTheLastImport() {
        let imported = Self.start
        #expect(
            !SignInReminder.due(
                now: imported + 6 * Self.day, imported: imported, since: imported, reminded: nil, on: true))
        #expect(
            SignInReminder.due(
                now: imported + 7 * Self.day, imported: imported, since: imported, reminded: nil, on: true))
    }

    @Test func withoutAnImportCountsFromFirstSeen() {
        #expect(
            !SignInReminder.due(
                now: Self.start + 3 * Self.day, imported: nil, since: Self.start, reminded: nil, on: true))
        #expect(
            SignInReminder.due(
                now: Self.start + 8 * Self.day, imported: nil, since: Self.start, reminded: nil, on: true))
    }

    @Test func onceAWeekAndNeverWhenOff() {
        let now = Self.start + 20 * Self.day
        #expect(
            !SignInReminder.due(
                now: now, imported: Self.start, since: Self.start, reminded: now - 2 * Self.day, on: true))
        #expect(
            SignInReminder.due(
                now: now, imported: Self.start, since: Self.start, reminded: now - 7 * Self.day, on: true))
        #expect(!SignInReminder.due(now: now, imported: Self.start, since: Self.start, reminded: nil, on: false))
    }
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1304
