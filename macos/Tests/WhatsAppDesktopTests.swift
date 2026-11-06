import Foundation
import Testing

@testable import Latchkey

/// Spec 012 plan D3b and the security reviews of 2026-11-05: a bubble in WhatsApp for Mac's window is
/// taken for a message only field by field (side, exactly its words, exactly its date and time), as
/// WhatsApp for Mac labelled its bubbles on 2026-11-05: "‎Your message, Latchkey check: text
/// 05:21:55Z, November 4, at 21:22, ‎Sent to ‎You, ‎Red"; today's "…, 18:15, Sent to You, Red"; a
/// reply "Replying to You.\nYour message, <words>, 18:18, Sent to You, Red.\nQuoted message.\n<quoted>".
@Suite struct WhatsAppDesktopTests {
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func message(_ text: String, _ date: Date, fromMe: Bool = true, file: String? = nil) -> WhatsAppMessage {
        WhatsAppMessage(
            id: "1", chatID: "c", chatName: nil, date: date, fromMe: fromMe, sender: "",
            kind: file == nil ? "text" : "document", text: text, fileName: file, key: "K")
    }

    static let now = at(2026, 11, 5, 19, 0)

    @Test func aBubbleMatchesFieldByField() {
        let m = Self.message("on my way", Self.at(2026, 11, 4, 21, 22))
        let label = WAWindow.clean("\u{200E}Your message, on my way, November 4, at 21:22, \u{200E}Sent to \u{200E}You")
        #expect(WAWindow.matches(label, m, now: Self.now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "November 4", with: "November 3"), m, now: Self.now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "21:22", with: "21:23"), m, now: Self.now))
        // Words must be the whole field, not part of it.
        #expect(!WAWindow.matches(label, Self.message("my way", m.date), now: Self.now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "on my way", with: "oh, on my way"), m, now: Self.now))
        // Someone else's message never matches the Owner's bubble, and the other way round.
        #expect(!WAWindow.matches(label, Self.message("on my way", m.date, fromMe: false), now: Self.now))
        let theirs = "Message from Sarah, on my way, November 4, at 21:22, Received from Sarah"
        #expect(WAWindow.matches(theirs, Self.message("on my way", m.date, fromMe: false), now: Self.now))
        #expect(!WAWindow.matches(theirs, m, now: Self.now))
    }

    @Test func todaysBubblesCarryTheTimeAlone() {
        let m = Self.message("hi", Self.at(2026, 11, 5, 18, 15))
        #expect(WAWindow.matches("Your message, hi, 18:15, Sent to You, Red", m, now: Self.now))
        #expect(!WAWindow.matches("Your message, hi, November 5, at 18:15, Sent to You", m, now: Self.now))
        let older = Self.message("hi", Self.at(2026, 11, 3, 18, 15))
        #expect(!WAWindow.matches("Your message, hi, 18:15, Sent to You", older, now: Self.now))
        let lastYear = Self.message("hi", Self.at(2025, 11, 3, 18, 15))
        #expect(WAWindow.matches("Your message, hi, November 3, 2025, at 18:15, Sent", lastYear, now: Self.now))
    }

    /// A reply's bubble names the quoted words too; only its own line counts.
    @Test func aReplyIsMatchedOnItsOwnLineOnly() {
        let label = "Replying to You.\nYour message, yes, 18:18, Sent to You, Red.\nQuoted message.\nare you coming"
        #expect(WAWindow.matches(label, Self.message("yes", Self.at(2026, 11, 5, 18, 18)), now: Self.now))
        #expect(!WAWindow.matches(label, Self.message("are you coming", Self.at(2026, 11, 5, 18, 18)), now: Self.now))
    }

    @Test func aMessageWithoutWordsNeverMatches() {
        let photo = Self.message("", Self.at(2026, 11, 4, 21, 22))
        #expect(!WAWindow.matches("Your photo, November 4, at 21:22, Sent to You", photo, now: Self.now))
        let file = Self.message("", Self.at(2026, 11, 4, 21, 22), file: "check.txt")
        #expect(WAWindow.matches("Your document, check.txt, November 4, at 21:22, Sent to You", file, now: Self.now))
        // WhatsApp for Mac's database keeps a document's name without its extension as its text
        // (2026-11-05); the bubble shows the file name.
        let named = Self.message("check", Self.at(2026, 11, 4, 21, 22), file: "check.txt")
        #expect(WAWindow.matches("Your document, check.txt, November 4, at 21:22, Sent to You", named, now: Self.now))
    }

    /// The message box's quote panel: "Quoted message, Your message, <words>".
    @Test func theQuotePanelNamesSideAndWords() {
        let m = Self.message("are you coming", Self.at(2026, 11, 5, 18, 15))
        #expect(WAWindow.matchesQuote("Your message, are you coming", m))
        #expect(!WAWindow.matchesQuote("Your message, you coming", m))
        #expect(!WAWindow.matchesQuote("Message from Sam, are you coming", m))
    }

    @Test func chatRowsAreNamedUpToTheFirstComma() {
        #expect(WAWindow.rowName("\u{200E}1st Grade Parents, \u{200E}3 unread messages") == "1st Grade Parents")
        #expect(WAWindow.rowName("Muppelssonit") == "Muppelssonit")
        #expect(WAWindow.paneName("Messages in chat with \u{200E}You") == "You")
    }

    /// Security review 2026-11-05: keyboard or pointer use more recent than Latchkey's own keystrokes,
    /// within 3 seconds, stops it.
    @Test func theOwnersInputIsToldFromLatchkeysOwn() {
        let ownJustNow = Date().addingTimeInterval(-0.05)
        #expect(!WAWindow.ownerActed(since: ownJustNow, idle: 0.05), "Latchkey's own keystroke")
        let ownEarlier = Date().addingTimeInterval(-2)
        #expect(WAWindow.ownerActed(since: ownEarlier, idle: 0.5), "someone typed after Latchkey")
        #expect(!WAWindow.ownerActed(since: .distantPast, idle: 10), "nobody for 10 s")
    }
}
