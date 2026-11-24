import Foundation
import Testing

@testable import Latchkey

/// Regression cases of Mail (macos/scripts/state-check/cases.json), batch B.
@MainActor @Suite struct RegressionMailBTests {
    /// `count` emails of the last hours, newest first, as Mail's index gives them.
    nonisolated static func emails(_ count: Int) -> [MailCodes.Email] {
        (0..<count).map { i in
            MailCodes.Email(
                place: MailCodes.Place(id: Int64(100 + i), account: "ACCT", mailbox: "INBOX"),
                date: Date().addingTimeInterval(-Double(i) * 60), sender: "Shop <news@shop.example>",
                subject: "Note \(i)", unread: false)
        }
    }

    func findTool(returning count: Int) -> ToolEntry {
        let found = Self.emails(count)
        let source = MailCapability.Source(
            find: { _, _, _, _, limit in Array(found.prefix(limit)) },
            email: { id in found.first { $0.place.id == id } }, text: { _ in "Hello" }, content: { _ in nil },
            start: {}, isLocked: { false })
        let c = PendingCleanup(defaults: nil)
        c.isLocked = { false }
        c.deleter = { _ in }
        let cap = MailCapability.make(source: source, cleanup: c)
        return cap.readTools.first { $0.tool.name == "mail_find" }!
    }

    /// regressions.mail_find_says_cut_off (2026-11-22, 0.8.221): mail_find listed 30 emails without
    /// saying whether there were more. At the limit it says there may be more and how to narrow;
    /// below it, nothing about more.
    @Test func mailFindSaysWhenItStopsAtThirty() async {
        let full = await findTool(returning: 45).handler(.object(["hours": .number(168)])).plainText
        #expect(full.contains("email 100") && full.contains("email 129") && !full.contains("email 130"), "\(full)")
        #expect(full.contains("there may be more"), "\(full)")
        #expect(full.contains("narrow with from, subject, unread_only, or fewer hours"), "\(full)")

        let few = await findTool(returning: 29).handler(.object(["hours": .number(168)])).plainText
        #expect(few.contains("email 128"), "\(few)")
        #expect(!few.contains("may be more") && !few.contains("narrow"), "\(few)")
    }
}
