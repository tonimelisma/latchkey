import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// Regression cases of Messages (macos/scripts/state-check/cases.json), batch B.
@Suite struct RegressionMessagesBTests {
    /// regressions.messages_delete_uber_code_texts (0.8.223): two '[Uber] Your code' texts with the
    /// same text in one conversation were never deleted, since the window showed both and either
    /// could be the one. Messages' database says how many like it come later and earlier in the
    /// same conversation, on the same side, and that picks the one the window shows at that place.
    /// (The window itself, and what the error says it showed, need Messages on screen: not here.)
    @Test func identicalCodeTextsAreToldApartByHowManyLikeThemComeLater() throws {
        let db = try MessagesFixture.make()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        // Chat 3 holds M-7 "Your code is 123456" (seconds since 2001, as older macOS stored).
        // Two more alike from the site, one alike from the owner, one other text from the site.
        let t = Int64(MessagesFixture.t0 + 7200)
        var h: OpaquePointer?
        #expect(sqlite3_open(db.path, &h) == SQLITE_OK)
        let sql = """
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments)
              VALUES (40, 'M-40', 'Your code is 123456', 3, \(t + 100), 0, 0),
                     (41, 'M-41', 'Your code is 123456', 3, \(t + 200), 0, 0),
                     (42, 'M-42', 'Your code is 123456', 0, \(t + 300), 1, 0),
                     (43, 'M-43', 'Your code is 654321', 3, \(t + 400), 0, 0);
            INSERT INTO chat_message_join VALUES (3, 40, \(t + 100)), (3, 41, \(t + 200)), (3, 42, \(t + 300)),
              (3, 43, \(t + 400));
            """
        #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)

        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let first = try #require(try store.locate("M-7"))
        let middle = try #require(try store.locate("M-40"))
        let last = try #require(try store.locate("M-41"))
        #expect(first.text == "Your code is 123456")
        #expect((first.laterSame, first.earlierSame) == (2, 0), "the owner's own and another code don't count")
        #expect((middle.laterSame, middle.earlierSame) == (1, 1))
        #expect((last.laterSame, last.earlierSame) == (0, 2))

        // The window shows the three, top to bottom: each is found at its own place.
        let shown: [(String, CGFloat)] = [("bottom", 300), ("top", 100), ("centre", 200)]
        #expect(CodeTextWindow.pick(shown, laterSame: first.laterSame, earlierSame: first.earlierSame) == "top")
        #expect(CodeTextWindow.pick(shown, laterSame: middle.laterSame, earlierSame: middle.earlierSame) == "centre")
        #expect(CodeTextWindow.pick(shown, laterSame: last.laterSame, earlierSame: last.earlierSame) == "bottom")
        // Only two of the three shown: unsure, so nothing is deleted.
        #expect(CodeTextWindow.pick(Array(shown.prefix(2)), laterSame: 1, earlierSame: 1) == nil)
    }
}
