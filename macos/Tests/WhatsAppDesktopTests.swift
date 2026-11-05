import Foundation
import Testing

@testable import Latchkey

/// Spec 012 plan D3b and the security review of 2026-11-05: a bubble in WhatsApp for Mac's window is
/// taken for a message only on the same side, words, date, and time, as WhatsApp for Mac labels its
/// bubbles (seen 2026-11-05: "‎Your message, Latchkey check: text 05:21:55Z, November 4, at 21:22,
/// ‎Sent to ‎You, ‎Red").
@Suite struct WhatsAppDesktopTests {
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func message(_ text: String, _ date: Date, fromMe: Bool = true, file: String? = nil) -> WhatsAppMessage {
        WhatsAppMessage(
            id: "1", chatID: "c", chatName: nil, date: date, fromMe: fromMe, sender: "", kind: file == nil ? "text" : "document",
            text: text, fileName: file, key: "K")
    }

    @Test func aBubbleMatchesOnSideWordsDateAndTime() {
        let now = Self.at(2026, 11, 5, 14, 0)
        let m = Self.message("on my way", Self.at(2026, 11, 4, 21, 22))
        let label = WAWindow.clean("\u{200E}Your message, on my way, November 4, at 21:22, \u{200E}Sent to \u{200E}You")
        #expect(WAWindow.matches(label, m, now: now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "November 4", with: "November 3"), m, now: now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "21:22", with: "21:23"), m, now: now))
        #expect(!WAWindow.matches(label.replacingOccurrences(of: "on my way", with: "on the way"), m, now: now))
        // Someone else's message never matches the Owner's bubble, and the other way round.
        #expect(!WAWindow.matches(label, Self.message("on my way", m.date, fromMe: false), now: now))
        let theirs = "Message from Sarah, on my way, November 4, at 21:22, Received from Sarah"
        #expect(WAWindow.matches(theirs, Self.message("on my way", m.date, fromMe: false), now: now))
        #expect(!WAWindow.matches(theirs, m, now: now))
    }

    @Test func todaysBubblesCarryTheTimeAlone() {
        let now = Self.at(2026, 11, 5, 14, 0)
        let m = Self.message("hi", Self.at(2026, 11, 5, 13, 5))
        #expect(WAWindow.matches("Your message, hi, 13:05, Sent to You", m, now: now))
        #expect(!WAWindow.matches("Your message, hi, October 5, at 13:05, Sent to You", m, now: now))
        let older = Self.message("hi", Self.at(2026, 11, 3, 13, 5))
        #expect(!WAWindow.matches("Your message, hi, 13:05, Sent to You", older, now: now), "another day's time alone")
    }

    @Test func aMessageWithoutWordsNeverMatches() {
        let now = Self.at(2026, 11, 5, 14, 0)
        let photo = Self.message("", Self.at(2026, 11, 4, 21, 22))
        #expect(!WAWindow.matches("Your photo, November 4, at 21:22, Sent to You", photo, now: now))
        let file = Self.message("", Self.at(2026, 11, 4, 21, 22), file: "check.txt")
        #expect(WAWindow.matches("Your document, check.txt, November 4, at 21:22, Sent to You", file, now: now))
    }

    @Test func chatRowsAreNamedUpToTheFirstComma() {
        #expect(WAWindow.rowName("\u{200E}1st Grade Parents, \u{200E}3 unread messages") == "1st Grade Parents")
        #expect(WAWindow.rowName("Muppelssonit") == "Muppelssonit")
    }
}
