import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import Latchkey

/// The log as 0.8.24 until 2026-11-15 stored it, in one SwiftData database: every field of
/// today's entries, kept beside the sealed content.
enum LogBeforeFiles {
    @Model final class SealedActivity {
        #Index<SealedActivity>([\.at, \.seq], [\.seq], [\.keyID])

        var id: UUID
        var at: Date
        var sealed: Data
        var seq: Int = 0
        var mac: Data?
        var keyID: String = ""
        var kind: String = "action"
        var callID: String = ""
        var device: String = ""

        init(
            id: UUID, at: Date, sealed: Data, seq: Int, mac: Data?, keyID: String, kind: String, callID: String,
            device: String
        ) {
            self.id = id
            self.at = at
            self.sealed = sealed
            self.seq = seq
            self.mac = mac
            self.keyID = keyID
            self.kind = kind
            self.callID = callID
            self.device = device
        }
    }

    /// Writes `entries` as those versions did, chained, and returns the newest entry's record.
    @MainActor static func write(_ entries: [Activity], key: SymmetricKey, to dir: URL) throws -> Data {
        let reader = ActivityReader(files: TraceFiles(folder: dir.appending(path: "unused")), key: key)
        let container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(url: dir.appending(path: TraceStore.fileName)))
        var previous = ActivityReader.chainStart
        for (i, a) in entries.enumerated() {
            let seq = i + 1
            let mac = reader.mac(previous: previous, a, seq: seq)
            container.mainContext.insert(
                SealedActivity(
                    id: a.id, at: a.at, sealed: try reader.seal(a, seq: seq), seq: seq, mac: mac, keyID: reader.keyID,
                    kind: a.kind.rawValue, callID: a.callID ?? "", device: a.device ?? ""))
            previous = mac
        }
        try container.mainContext.save()
        return LatestEntryRecord.encode(keyID: reader.keyID, tip: ChainTip(seq: entries.count, mac: previous))
    }
}

/// Full traces in daily files (Toni, 2026-11-15; FR-680 to FR-682, FR-689,
/// contracts/trace-files.md).
@Suite struct TraceFilesTests {
    static func call(_ n: Int, at: Date, result: String? = nil) -> Activity {
        Activity(
            at: at, tool: "shell_run", arguments: "{\"command\":\"echo \(n)\"}",
            result: result ?? "[{\"type\":\"text\",\"text\":\"\(n)\"}]", isError: false, durationMS: n,
            callID: "call_\(n)", device: "dev_1", client: "Claude")
    }

    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    static func folder(_ dir: URL) -> URL { dir.appending(path: TraceStore.folderName) }

    static func bytes(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appending(path: name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out[name] = try Data(contentsOf: url)
            }
        }
        return out
    }

    /// FR-680: each entry goes to the files of the UTC day it began, named by the day, with its
    /// fields in the clear in the entries file and nothing readable in the content file.
    @MainActor @Test func entriesGoToTheFilesOfTheirDay() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey(), latest: MemoryLatestEntry())
        try trace.record(Self.call(1, at: Self.utc(2026, 11, 14, 23, 59, 59)))
        try trace.record(Self.call(2, at: Self.utc(2026, 11, 15, 0, 0, 1)))
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder(dir).path).sorted()
        #expect(names == ["2026-11-14.content", "2026-11-14.entries", "2026-11-15.content", "2026-11-15.entries"])
        let line = try String(contentsOf: Self.folder(dir).appending(path: "2026-11-15.entries"), encoding: .utf8)
        let fields = try #require(
            try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(fields["v"] as? Int == 1)
        #expect(fields["seq"] as? Int == 2)
        #expect(fields["call_id"] as? String == "call_2")
        #expect(fields["time"] as? String == "2026-11-15T00:00:01.000Z")
        #expect(fields["off"] as? Int == 0)
        let content = try Data(contentsOf: Self.folder(dir).appending(path: "2026-11-15.content"))
        #expect(content.count == fields["len"] as? Int)
        #expect(content.range(of: Data("echo 2".utf8)) == nil, "the content is encrypted")
        #expect(try trace.page(limit: 10).entries.map(\.durationMS) == [2, 1])
    }

    /// FR-681: recording only ever adds to the end of a file.
    @MainActor @Test func filesAreOnlyAppendedTo() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record((1...3).map { Self.call($0, at: now.addingTimeInterval(Double($0))) })
        }
        let before = try Self.bytes(Self.folder(dir))
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        try trace.record((4...6).map { Self.call($0, at: now.addingTimeInterval(Double($0))) })
        let after = try Self.bytes(Self.folder(dir))
        for (name, old) in before {
            let new = try #require(after[name])
            #expect(new.count > old.count, "\(name) grew")
            #expect(new.prefix(old.count) == old, "\(name) kept every byte it had")
        }
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
    }

    /// FR-681: a line cut short (a crash mid-write) and a line of a later format are skipped and
    /// counted, never changed, and the next entry starts on a line of its own.
    @MainActor @Test func linesThatCannotBeReadAreSkippedAndKept() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record(Self.call(1, at: now))
        }
        let entries = Self.folder(dir).appending(path: TraceFiles.day(now) + TraceFiles.entriesSuffix)
        let handle = try FileHandle(forWritingTo: entries)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":2,\"what\":\"a later format\"}\n{\"v\":1,\"seq\":7,\"id\":\"".utf8))
        try handle.close()
        let written = try Data(contentsOf: entries)

        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        let page = try trace.page(limit: 10)
        #expect(page.entries.map(\.durationMS) == [1])
        #expect(page.unreadable == 2, "both lines counted")
        try trace.record(Self.call(2, at: now.addingTimeInterval(1)))
        let after = try Data(contentsOf: entries)
        #expect(after.prefix(written.count) == written, "the lines are left as they were")
        #expect(try trace.page(limit: 10).entries.map(\.durationMS) == [2, 1], "the next entry still reads")
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
    }

    /// FR-682: the database's entries are copied unchanged (the chain and the Keychain record
    /// still check), the database's files aren't touched, and a second start copies nothing.
    @MainActor @Test func copiesTheDatabaseOnceAndLeavesItUntouched() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let now = Date()
        let old = (1...5).map { Self.call($0, at: now.addingTimeInterval(Double($0 - 10) * 3600)) }
        let record = try LogBeforeFiles.write(old, key: try keys.loadOrCreate(), to: dir)
        let latest = MemoryLatestEntry(.found(record))
        let database = try Self.bytes(dir)
        #expect(database.keys.contains(TraceStore.fileName))

        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            #expect(trace.copiedFromDatabase == 5)
            let actions = try trace.reader.page(ActivityQuery(kind: .action), limit: 10).entries
            #expect(actions.map(\.callID) == ["call_5", "call_4", "call_3", "call_2", "call_1"])
            #expect(actions.map(\.seq) == [5, 4, 3, 2, 1], "numbers kept")
            #expect(try trace.reader.check(expected: trace.expected) == LogCheck(), "the chain still checks")
            let event = try #require(try trace.reader.page(ActivityQuery(kind: .event), limit: 1).entries.first)
            #expect(event.result.hasPrefix("The activity log moved into daily files: 5 entries copied"))
            #expect(try trace.reader.calls().calls.count == 5)
        }
        #expect(try Self.bytes(dir) == database, "the database's files are exactly as they were")
        let again = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(again.copiedFromDatabase == 0)
        #expect(try again.reader.page(ActivityQuery(kind: .action), limit: 10).entries.count == 5)
    }

    /// FR-682, all or nothing: a copy cut short is thrown away and made again; a database that
    /// can't be read leaves no daily files behind, so the next start tries again.
    @MainActor @Test func anInterruptedCopyStartsOverAndAFailedOneCountsForNothing() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let now = Date()
        _ = try LogBeforeFiles.write(
            (1...3).map { Self.call($0, at: now.addingTimeInterval(Double($0))) }, key: try keys.loadOrCreate(), to: dir
        )
        let copying = dir.appending(path: TraceStore.copyingName)
        try FileManager.default.createDirectory(at: copying, withIntermediateDirectories: true)
        try Data("half a copy".utf8).write(to: copying.appending(path: "2026-01-01.entries"))
        let trace = try TraceStore(directory: dir, keys: keys, latest: MemoryLatestEntry())
        #expect(trace.copiedFromDatabase == 3)
        #expect(!FileManager.default.fileExists(atPath: copying.path))
        #expect(try trace.reader.page(ActivityQuery(kind: .action), limit: 10).entries.count == 3)
        #expect(try trace.reader.page(ActivityQuery(), limit: 10).unreadable == 0, "nothing of the half copy")

        let broken = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: broken) }
        let garbage = Data("this is not a database".utf8)
        try garbage.write(to: broken.appending(path: TraceStore.fileName))
        #expect(throws: (any Error).self) {
            try TraceStore(directory: broken, keys: MemoryTraceKey(), latest: MemoryLatestEntry())
        }
        #expect(!FileManager.default.fileExists(atPath: Self.folder(broken).path), "not marked as copied")
        #expect(try Data(contentsOf: broken.appending(path: TraceStore.fileName)) == garbage)
    }

    /// A call that began before midnight (UTC) and ended after is filed under the earlier day
    /// although it was written after entries of the later one; the chain continues from it.
    @MainActor @Test func aCallAcrossMidnightKeepsTheChain() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record(Self.call(1, at: Self.utc(2026, 11, 15, 0, 0, 5)))
            try trace.record(Self.call(2, at: Self.utc(2026, 11, 14, 23, 59, 50)))
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        try trace.record(Self.call(3, at: Self.utc(2026, 11, 15, 0, 1)))
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
        #expect(try trace.page(limit: 10).entries.map(\.seq) == [3, 1, 2], "newest first by time")
    }

    /// FR-681: the code that keeps the daily files only appends; no other part of the app names
    /// their folder (uninstalling removes the whole data folder, FR-077).
    @Test func noCodeRewritesOrDeletesTraceFiles() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App")
            .standardizedFileURL
        let trace = try String(contentsOf: app.appendingPathComponent("Trace.swift"), encoding: .utf8)
        let start = try #require(trace.range(of: "struct TraceFiles: Sendable {"))
        let end = try #require(trace.range(of: "struct ActivityReader: Sendable {"))
        let body = trace[start.upperBound..<end.lowerBound]
        for call in [
            "removeItem", "truncate", "moveItem", "replaceItem", "write(to:", "atomically",
            "createFile(atPath: url.path, contents: Data",
        ] {
            #expect(!body.contains(call), "TraceFiles must only append: \(call)")
        }
        let files = try FileManager.default.subpathsOfDirectory(atPath: app.path).filter {
            $0.hasSuffix(".swift") && $0 != "Trace.swift"
        }
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !text.contains("TraceStore.folderName") && !text.contains("TraceFiles("),
                "\(file) touches the trace files")
        }
    }

    /// A changed line whose place in the content file overflows when added up is an entry that
    /// can't be opened, not a crash (security review, 2026-11-15).
    @Test func aPlaceThatOverflowsIsNotOpened() {
        let row = TraceRow(
            id: UUID(), at: Date(), seq: 1, keyID: "", kind: "action", callID: "", device: "", day: "2026-11-15",
            off: Int.max, len: Int.max)
        #expect(TraceFiles.sealed(row, in: Data([1, 2, 3])) == nil)
        var tail = row
        tail.off = 2
        tail.len = 5
        #expect(TraceFiles.sealed(tail, in: Data([1, 2, 3])) == nil)
        tail.len = 1
        #expect(TraceFiles.sealed(tail, in: Data([1, 2, 3])) == Data([3]))
    }

    /// FR-680: a result as large as a screenshot is kept whole.
    @MainActor @Test func keepsLargeResultsWhole() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let image = String(repeating: "A", count: 4_000_000)
        let result = "[{\"type\":\"image\",\"data\":\"\(image)\"}]"
        try trace.record(Self.call(1, at: Date(), result: result))
        let back = try #require(try trace.page(limit: 1).entries.first)
        #expect(back.result == result)
        #expect(trace.diskBytes > 4_000_000, "FR-689: the files are counted")
    }
}
