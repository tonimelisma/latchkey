import Foundation
import Testing

@testable import Latchkey

/// Spec 008 FR-840: what Mail's scripting is asked, so a message is made with Mail behind.
@Suite struct MailScriptedTests {
    @Test func aNewMessageCarriesItsSubjectAndEveryRecipient() throws {
        let url = try #require(
            MailCompose.mailto(
                to: ["sam@example.com", "bob@example.com"], cc: ["cc@example.com"], bcc: ["bcc@example.com"],
                subject: "Lunch & co?"))
        #expect(
            AXMailWindows.makeArguments(.new(mailto: url)) == [
                "new", "Lunch & co?", "to", "sam@example.com", "to", "bob@example.com", "cc", "cc@example.com", "bcc",
                "bcc@example.com",
            ])
    }

    @Test func responsesNameTheOriginalsPlace() {
        let place = MessagePlace(accountID: "ACCT", path: "INBOX", id: 1001)
        #expect(
            AXMailWindows.makeArguments(.respond(messageID: "<m@x>", kind: .reply, place: place)) == [
                "reply", "ACCT", "INBOX", "1001",
            ])
        #expect(
            AXMailWindows.makeArguments(.respond(messageID: "<m@x>", kind: .replyAll, place: place))?.first
                == "replyAll")
        #expect(
            AXMailWindows.makeArguments(.respond(messageID: "<m@x>", kind: .forward, place: place))?.first == "forward")
    }

    @Test func withoutAPlaceMailComesForwardInstead() {
        #expect(AXMailWindows.makeArguments(.respond(messageID: "<m@x>", kind: .reply)) == nil)
    }

    /// 2026-11-02: a draft closed at once after saving was lost.
    @Test func savingWaitsBeforeClosing() {
        let s = AXMailWindows.messageScript
        let save = try! #require(s.range(of: "save m"))
        let delay = try! #require(s.range(of: "delay 3"))
        let close = try! #require(s.range(of: "close m saving no", range: delay.upperBound..<s.endIndex))
        #expect(save.upperBound <= delay.lowerBound && delay.upperBound <= close.lowerBound)
    }
}
