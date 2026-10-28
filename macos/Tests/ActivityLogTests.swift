import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import Latchkey

/// The log as 0.8.14 and earlier stored it: time, ID, and the sealed entry, nothing else.
enum LogBeforeTheCheck {
    @Model final class SealedActivity {
        var id: UUID
        var at: Date
        var sealed: Data

        init(id: UUID, at: Date, sealed: Data) {
            self.id = id
            self.at = at
            self.sealed = sealed
        }
    }

    /// Seals an entry the way those versions did: the JSON, no bound data.
    static func seal(_ a: Activity, _ key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(try JSONEncoder().encode(a), using: key).combined!
    }
}

/// The activity log kept for good (Toni, 2026-10-26): the tamper check's chain (FR-612), the
/// record of the newest entry (FR-613), browsing and searching (FR-614), and Export… (FR-615).
@Suite struct ActivityLogTests {
    static func entry(_ n: Int, at: Date, tool: String = "shell_run", result: String? = nil) -> Activity {
        Activity(
            at: at, tool: tool, arguments: "{\"command\":\"echo \(n)\"}", result: result ?? "output \(n)",
            isError: false, durationMS: n)
    }

    /// A log on disk with `count` checked entries one minute apart, the newest a minute ago.
    @MainActor static func log(
        _ count: Int, in dir: URL, keys: MemoryTraceKey, latest: MemoryLatestEntry
    ) throws -> [Activity] {
        let now = Date()
        let entries = (1...count).map { entry($0, at: now.addingTimeInterval(Double($0 - count - 1) * 60)) }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        for e in entries { try trace.record(e) }
        return entries
    }

    /// Changes the stored rows directly, as another program could.
    static func tamper(_ dir: URL, _ change: (ModelContext, [SealedActivity]) throws -> Void) throws {
        let container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(url: dir.appending(path: TraceStore.fileName)))
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SealedActivity>(sortBy: [SortDescriptor(\.seq)]))
        try change(context, rows)
        try context.save()
    }

    @MainActor static func check(_ dir: URL, _ keys: MemoryTraceKey, _ latest: MemoryLatestEntry) throws -> LogCheck {
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        return try trace.reader.check(expected: trace.expected)
    }

    // MARK: upgrade

    /// FR-612: Toni's entries from before the check stay readable after the upgrade, are marked
    /// as from before the check, and entries under a key that is gone are still only counted.
    @MainActor @Test func upgradesTheLogFromBeforeTheCheck() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let key = try keys.loadOrCreate()
        let now = Date()
        do {
            let old = try ModelContainer(
                for: LogBeforeTheCheck.SealedActivity.self,
                configurations: ModelConfiguration(url: dir.appending(path: TraceStore.fileName)))
            for n in 1...3 {
                let a = Self.entry(n, at: now.addingTimeInterval(Double(n - 10) * 60))
                old.mainContext.insert(
                    LogBeforeTheCheck.SealedActivity(id: a.id, at: a.at, sealed: try LogBeforeTheCheck.seal(a, key)))
            }
            let lost = Self.entry(9, at: now.addingTimeInterval(-3600))
            old.mainContext.insert(
                LogBeforeTheCheck.SealedActivity(
                    id: lost.id, at: lost.at, sealed: try LogBeforeTheCheck.seal(lost, SymmetricKey(size: .bits256))))
            try old.mainContext.save()
        }

        let latest = MemoryLatestEntry()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            let page = try trace.page(limit: 100)
            #expect(page.entries.map(\.result) == ["output 3", "output 2", "output 1"], "readable after the upgrade")
            #expect(page.entries.allSatisfy { $0.beforeCheck }, "marked as from before the check")
            #expect(page.unreadable == 1, "the entry under a lost key is counted, not shown")
            #expect(page.changed.isEmpty)
            let check = try trace.reader.check(expected: trace.expected)
            #expect(check.broken.isEmpty)
            #expect(!check.missingNewer)
            #expect(check.beforeCheck == 3)
            #expect(latest.writes.isEmpty, "nothing to record yet")

            try trace.record(Self.entry(4, at: now))
            #expect(latest.writes == ["add"])
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        let page = try trace.page(limit: 100)
        #expect(page.entries.map(\.result) == ["output 4", "output 3", "output 2", "output 1"])
        #expect(page.entries.map(\.beforeCheck) == [false, true, true, true])
        #expect(page.unreadable == 1)
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck(beforeCheck: 3))
    }

    // MARK: the chain (FR-612)

    @MainActor @Test func anUntouchedLogChecksOut() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(5, in: dir, keys: keys, latest: latest)
        #expect(latest.writes == ["add", "update", "update", "update", "update"])
        let check = try Self.check(dir, keys, latest)
        #expect(check == LogCheck())
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(try trace.page(limit: 10).entries.map(\.seq) == [5, 4, 3, 2, 1])
    }

    @MainActor @Test func removingAnEntryIsCaughtWhereItWas() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let entries = try Self.log(5, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { context, rows in context.delete(rows[2]) }
        let check = try Self.check(dir, keys, latest)
        #expect(check.broken.map(\.seq) == [4], "the entry after the removed one doesn't follow")
        #expect(abs(check.broken[0].at.timeIntervalSince(entries[3].at)) < 0.001)
        #expect(!check.missingNewer)
    }

    @MainActor @Test func changingAnEntryIsCaught() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(5, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { _, rows in rows[1].at = rows[1].at.addingTimeInterval(-86_400) }
        #expect(try Self.check(dir, keys, latest).broken.map(\.seq) == [2], "a changed time")

        // Content swapped in from another entry no longer opens: it is counted as changed.
        try Self.tamper(dir) { _, rows in rows[3].sealed = rows[4].sealed }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        let page = try trace.page(limit: 10)
        #expect(page.entries.map(\.seq) == [5, 3, 1, 2], "newest first by the stored time, changed one included")
        #expect(page.changed.count == 1)
        #expect(page.unreadable == 0, "not mistaken for an entry under a lost key")
    }

    @MainActor @Test func reorderingIsCaught() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(5, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { _, rows in (rows[1].seq, rows[2].seq) = (rows[2].seq, rows[1].seq) }
        #expect(!(try Self.check(dir, keys, latest).broken.isEmpty))
    }

    /// Making a checked entry look like one from before the check doesn't hide its removal.
    @MainActor @Test func relabellingAnEntryIsCaught() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(5, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { _, rows in rows[1].seq = 0 }
        #expect(try Self.check(dir, keys, latest).broken.map(\.seq) == [3])
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(try trace.page(limit: 10).changed.count == 1, "its content no longer opens either")
    }

    // MARK: the record of the newest entry (FR-613)

    @MainActor @Test func cuttingOffTheEndIsCaughtAndStaysCaught() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let entries = try Self.log(5, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { context, rows in
            context.delete(rows[4])
            context.delete(rows[3])
        }
        let check = try Self.check(dir, keys, latest)
        #expect(check.broken.isEmpty, "what is left still chains")
        #expect(check.missingNewer)
        #expect(abs((check.lastPresent ?? .distantPast).timeIntervalSince(entries[2].at)) < 0.001)

        // The next entry continues from the record, so the gap stays in the chain for good.
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record(Self.entry(6, at: Date()))
        }
        let after = try Self.check(dir, keys, latest)
        #expect(!after.missingNewer)
        #expect(after.broken.map(\.seq) == [6])
    }

    /// A start right after an entry was saved but before the record moved on (the app stopped
    /// in between): no alarm.
    @MainActor @Test func aRecordOneBehindIsNoAlarm() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(2, in: dir, keys: keys, latest: latest)
        let behind = latest.stored
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record(Self.entry(3, at: Date()))
        }
        latest.set(behind)
        #expect(try Self.check(dir, keys, latest) == LogCheck())
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        try trace.record(Self.entry(4, at: Date()))
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck(), "continues from the log's newest")
    }

    /// "Couldn't read it" is not "isn't there": the record is left alone, and no alarm is raised
    /// because nothing can be told.
    @MainActor @Test func aRecordThatCannotBeReadIsLeftAloneAndRaisesNoAlarm() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(4, in: dir, keys: keys, latest: latest)
        try Self.tamper(dir) { context, rows in context.delete(rows[3]) }
        latest.set(.unreadable("Keychain error -25308"))

        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(trace.latestState == .unreadable("Keychain error -25308"))
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck(), "no alarm it can't back")
        try trace.record(Self.entry(5, at: Date()))
        #expect(latest.writes.count == 4, "not written over: \(latest.writes)")
        #expect(latest.stored == .unreadable("Keychain error -25308"))
        #expect(
            ActivityFormat.latestNote(trace.latestState)
                == "Latchkey couldn’t read its record of the newest entry in the Keychain, so it can’t check right now whether newer entries were removed. It tries again each time it opens."
        )
    }

    @MainActor @Test func aRecordThisVersionDoesNotUnderstandIsLeftAlone() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let latest = MemoryLatestEntry(.found(Data([9, 9, 9])))
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey(), latest: latest)
        try trace.record(Self.entry(1, at: Date()))
        #expect(latest.stored == .found(Data([9, 9, 9])))
        #expect(latest.writes.isEmpty)
        if case .unreadable = trace.latestState {} else { Issue.record("said: \(trace.latestState)") }
    }

    @MainActor @Test func aMissingRecordIsSaidAndStartedAgain() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        _ = try Self.log(3, in: dir, keys: keys, latest: latest)
        latest.delete()
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(trace.latestState == .missing)
        #expect(
            ActivityFormat.latestNote(.missing)
                == "Latchkey’s record of the newest entry is missing from the Keychain, so it can’t tell whether entries were removed from the end of the log before now."
        )
        #expect(ActivityFormat.latestNote(.ok) == nil)
        try trace.record(Self.entry(4, at: Date()))
        #expect(latest.writes.last == "add")
        #expect(try Self.check(dir, keys, latest) == LogCheck())
        #expect(try TraceStore(directory: dir, keys: keys, latest: latest).latestState == .ok)
    }

    /// A fresh log needs no record yet, so nothing is said.
    @MainActor @Test func aNewLogHasNothingToSay() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        #expect(trace.latestState == .ok)
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
    }

    /// A record left by an earlier key (the key was lost and a new one made) is replaced.
    @MainActor @Test func aRecordOfAnEarlierKeyIsReplaced() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let latest = MemoryLatestEntry()
        _ = try Self.log(2, in: dir, keys: MemoryTraceKey(), latest: latest)
        let keys = MemoryTraceKey()
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(trace.latestState == .ok)
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
        try trace.record(Self.entry(3, at: Date()))
        #expect(latest.writes.last == "update")
        let page = try trace.page(limit: 10)
        #expect(page.entries.map(\.seq) == [3], "numbers go on across keys")
        #expect(page.unreadable == 2)
        #expect(try Self.check(dir, keys, latest) == LogCheck())
    }

    @Test func theRecordIsSmallAndExact() throws {
        let tip = ChainTip(seq: 123_456, mac: Data((0..<32).map { UInt8($0) }))
        let data = LatestEntryRecord.encode(keyID: "0123456789abcdef", tip: tip)
        #expect(data.count == 57)
        let back = try #require(LatestEntryRecord.decode(data))
        #expect(back.keyID == "0123456789abcdef")
        #expect(back.tip == tip)
        #expect(LatestEntryRecord.decode(data.dropLast()) == nil)
        var other = data
        other[0] = 2
        #expect(LatestEntryRecord.decode(other) == nil, "a later version's record isn't guessed at")
    }

    // MARK: kept on Disconnect and pairing again (FR-611)

    /// Disconnect, the relay revoking the Mac (both `DeviceIdentity.delete`), and pairing again
    /// (`DeviceIdentity.save`) touch only the pairing's own items: the log key and the record of
    /// the newest entry stay, and so does the log.
    @MainActor @Test func disconnectingAndPairingAgainKeepTheLog() throws {
        let vault = MemoryVault()
        vault.items = [
            Keychain.traceKeyAccount: Data(repeating: 7, count: 32), Keychain.latestEntryAccount: Data([1, 2]),
        ]
        try DeviceIdentity.save(
            relayURL: URL(string: "https://relay.example.com")!, deviceID: "dev_1", keyData: Data([1]), vault: vault)
        DeviceIdentity.delete(vault: vault)
        try DeviceIdentity.save(
            relayURL: URL(string: "https://relay.example.com")!, deviceID: "dev_2", keyData: Data([2]), vault: vault)
        #expect(vault.items[Keychain.traceKeyAccount] == Data(repeating: 7, count: 32))
        #expect(vault.items[Keychain.latestEntryAccount] == Data([1, 2]))
        #expect(
            !vault.changes.contains {
                $0.hasSuffix(Keychain.traceKeyAccount) || $0.hasSuffix(Keychain.latestEntryAccount)
            },
            "\(vault.changes)")
    }

    // MARK: browsing (FR-614)

    @MainActor @Test func pagesFollowOnWithoutGapsOrRepeats() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let now = Date()
        try trace.record((1...120).map { Self.entry($0, at: now.addingTimeInterval(Double($0) - 200)) })
        var seen: [Int] = []
        var cursor: ActivityCursor?
        var pages = 0
        repeat {
            let page = try trace.reader.page(ActivityQuery(), after: cursor, limit: 50)
            seen += page.entries.map(\.durationMS)
            cursor = page.next
            pages += 1
        } while cursor != nil
        #expect(seen == Array((1...120).reversed()))
        #expect(pages == 3)
    }

    @MainActor @Test func searchesTextToolAndDates() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let day = 86_400.0
        let now = Date()
        try trace.record([
            Self.entry(1, at: now.addingTimeInterval(-10 * day), tool: "files_read", result: "Quarterly REPORT"),
            Self.entry(2, at: now.addingTimeInterval(-5 * day), tool: "shell_run", result: "report done"),
            Self.entry(3, at: now.addingTimeInterval(-1 * day), tool: "files_read", result: "nothing here"),
            Self.entry(4, at: now, tool: "notes_read", result: "Café list"),
        ])
        func found(_ q: ActivityQuery) throws -> [Int] { try trace.reader.page(q, limit: 10).entries.map(\.durationMS) }
        #expect(try found(ActivityQuery(text: "report")) == [2, 1], "any case")
        #expect(try found(ActivityQuery(text: "cafe")) == [4], "any accent")
        #expect(try found(ActivityQuery(text: "echo 3")) == [3], "arguments too")
        #expect(try found(ActivityQuery(tool: "files_read")) == [3, 1])
        #expect(try found(ActivityQuery(text: "report", tool: "files_read")) == [1])
        #expect(try found(ActivityQuery(from: now.addingTimeInterval(-6 * day), to: now)) == [3, 2], "to is exclusive")
        #expect(try found(ActivityQuery(text: "zzz")).isEmpty)
        let one = try trace.reader.page(ActivityQuery(tool: "files_read"), limit: 1)
        #expect(one.entries.map(\.durationMS) == [3])
        #expect(
            try trace.reader.page(ActivityQuery(tool: "files_read"), after: one.next, limit: 1).entries.map(
                \.durationMS) == [1])
    }

    @MainActor @Test func theWindowSaysHowMuchSpaceTheLogUses() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey(), latest: MemoryLatestEntry())
        let before = trace.diskBytes
        #expect(before > 0)
        try trace.record((1...200).map { Self.entry($0, at: Date(), result: String(repeating: "x", count: 4000)) })
        #expect(trace.diskBytes > before + 200 * 1000, "\(before) → \(trace.diskBytes)")
        #expect(try TraceStore(inMemory: true, keys: MemoryTraceKey()).diskBytes == 0)
        #expect(ActivityFormat.footnote(bytes: 12_300_000).hasSuffix("It uses 12.3 MB."))
    }

    /// The window's warnings, most serious first; none when the check found nothing.
    @Test func theWindowWarnsInPlainWords() {
        #expect(ActivityFormat.warnings(check: LogCheck(), changed: 0).isEmpty)
        #expect(ActivityFormat.warnings(check: nil, changed: 0).isEmpty, "while the check runs")
        let when = Date(timeIntervalSince1970: 1_793_000_000)
        let all = ActivityFormat.warnings(
            check: LogCheck(broken: [ActivityCursor(at: when, seq: 7)], missingNewer: true, lastPresent: when),
            changed: 2)
        #expect(all.count == 3)
        #expect(all[0].hasPrefix("Newer entries are missing from the activity log. Entries after "))
        #expect(all[0].hasSuffix(" were removed outside Latchkey, or lost when the Mac shut down unexpectedly."))
        #expect(all[1].hasPrefix("The activity log was changed outside Latchkey. Starting with the entry from "))
        #expect(all[1].contains(when.formatted(date: .abbreviated, time: .standard)), "names where it starts")
        #expect(all[2] == "2 entries were changed outside Latchkey and can’t be shown.")
        #expect(
            ActivityFormat.warnings(check: nil, changed: 1) == [
                "1 entry was changed outside Latchkey and can’t be shown."
            ])
        #expect(ActivityFormat.beforeCheckNote(0) == nil)
        #expect(ActivityFormat.beforeCheckNote(3) != nil)
    }

    @Test func dateRangesCoverWholeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15)))
        let today = calendar.startOfDay(for: now)
        func span(_ r: ActivityRange, _ a: Date = now, _ b: Date = now) -> (Date?, Date?) {
            r.span(now: now, customFrom: a, customTo: b, calendar: calendar)
        }
        #expect(span(.anyTime) == (nil, nil))
        #expect(span(.today) == (today, nil))
        #expect(span(.week).0 == calendar.date(byAdding: .day, value: -6, to: today), "today and the six before")
        let earlier = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let custom = span(.custom, now, earlier)
        #expect(custom.0 == calendar.startOfDay(for: earlier), "either order")
        #expect(custom.1 == calendar.date(byAdding: .day, value: 1, to: today), "the last day included")
    }

    // MARK: Export… (FR-615)

    @Test func anExportedLineIsReadable() throws {
        let format = ActivityExport(timeZone: TimeZone(secondsFromGMT: -7 * 3600)!)
        let a = Activity(
            at: Date(timeIntervalSince1970: 1_793_000_000.25), tool: "files_read",
            arguments: "{\"path\":\"/Users/toni/a.txt\"}", result: "[{\"type\":\"text\",\"text\":\"hi\"}]",
            isError: true, durationMS: 42)
        #expect(
            format.line(a)
                == #"{"time":"2026-10-26T00:33:20.250-07:00","kind":"action","tool":"files_read","arguments":{"path":"/Users/toni/a.txt"},"result":[{"text":"hi","type":"text"}],"isError":true,"durationMS":42,"call_id":null,"client":null}"#
                || format.line(a)
                    == #"{"time":"2026-10-26T00:33:20.250-07:00","kind":"action","tool":"files_read","arguments":{"path":"/Users/toni/a.txt"},"result":[{"type":"text","text":"hi"}],"isError":true,"durationMS":42,"call_id":null,"client":null}"#,
            "\(format.line(a))")
        let plain = Activity(
            at: Date(timeIntervalSince1970: 0), tool: "remove_access", arguments: "Claude (claude.ai)",
            result: "Removed.", isError: false, durationMS: 0)
        let line = ActivityExport(timeZone: TimeZone(secondsFromGMT: 0)!).line(plain)
        #expect(line.contains(#""time":"1970-01-01T00:00:00.000Z""#))
        #expect(line.contains(#""arguments":"Claude (claude.ai)""#), "text that isn't JSON stays a string")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "time", "kind", "tool", "arguments", "result", "isError", "durationMS", "call_id", "client",
            ])
    }

    @MainActor @Test func exportWritesWhatTheWindowSelectsOldestFirst() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let now = Date()
        try trace.record(
            (1...2500).map { Self.entry($0, at: now.addingTimeInterval(Double($0)), tool: $0 % 2 == 0 ? "a_b" : "c_d") }
        )
        let url = dir.appending(path: "export.jsonl")
        try "old content that must go".write(to: url, atomically: true, encoding: .utf8)
        #expect(try trace.reader.export(ActivityQuery(tool: "a_b"), to: url) == 1250)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1250)
        let durations = try lines.map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["durationMS"] as? Int
        }
        #expect(durations == Array(stride(from: 2, through: 2500, by: 2)))
    }
}
