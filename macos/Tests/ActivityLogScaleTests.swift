import Foundation
import Testing

@testable import Latchkey

/// Years of entries (FR-614): 100,000 generated entries on disk, about 1 KB each. Prints how long
/// each step takes, and fails only on a step slow enough for the Owner to notice.
@Suite(.serialized) struct ActivityLogScaleTests {
    static let count = 100_000

    @MainActor @Test func aHundredThousandEntries() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        var timings: [(String, Double)] = []
        func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            timings.append((name, Date().timeIntervalSince(start)))
            return value
        }

        let start = Date().addingTimeInterval(-Double(Self.count) * 600)  // one every 10 minutes: ~2 years
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 36)  // ~1 KB
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try time("record 100k (batches of 1,000)") {
                for chunk in stride(from: 0, to: Self.count, by: 1000) {
                    try trace.record(
                        (chunk..<chunk + 1000).map { n in
                            Activity(
                                at: start.addingTimeInterval(Double(n) * 600),
                                tool: n % 3 == 0 ? "files_read" : "shell_run",
                                arguments: "{\"command\":\"echo \(n)\"}",
                                result: n == 1234 ? "needle-in-the-haystack" : "\(filler) \(n)", isError: false,
                                durationMS: n)
                        })
                }
            }
        }
        let trace = try time("open the log") { try TraceStore(directory: dir, keys: keys, latest: latest) }
        let first = try time("first page (200)") { try trace.reader.page(ActivityQuery(), limit: 200) }
        #expect(first.entries.count == 200)
        #expect(first.unreadable == 0)
        let second = try time("next page (200)") {
            try trace.reader.page(ActivityQuery(), after: first.next, limit: 200)
        }
        #expect(second.entries.first?.durationMS == Self.count - 201)
        _ = try time("menu (10 newest)") { try trace.recent(limit: 10) }
        let check = try time("tamper check, whole log") { try trace.reader.check(expected: trace.expected) }
        #expect(check == LogCheck())
        let rare = try time("text search, whole log (1 match)") {
            try trace.reader.page(ActivityQuery(text: "needle-in-the"), limit: 200)
        }
        #expect(rare.entries.map(\.durationMS) == [1234])
        #expect(rare.next == nil)
        let tool = try time("tool filter, first page") {
            try trace.reader.page(ActivityQuery(tool: "files_read"), limit: 200)
        }
        #expect(tool.entries.count == 200)
        let month = try time("last 30 days, first page") {
            try trace.reader.page(
                ActivityQuery(from: start.addingTimeInterval(Double(Self.count) * 600 - 30 * 86_400)), limit: 200)
        }
        #expect(month.entries.count == 200)
        let url = dir.appending(path: "export.jsonl")
        let exported = try time("export whole log") { try trace.reader.export(ActivityQuery(), to: url) }
        #expect(exported == Self.count)
        let disk = trace.diskBytes

        let report =
            timings.map { String(format: "%-36@ %8.3f s", $0.0 as NSString, $0.1) }.joined(separator: "\n")
            + "\nlog on disk: \(ByteCountFormatter.string(fromByteCount: disk, countStyle: .file))"
        print("Activity log, \(Self.count) entries:\n\(report)")
        try? report.write(
            to: FileManager.default.temporaryDirectory.appending(path: "latchkey-activity-scale.txt"), atomically: true,
            encoding: .utf8)
        let seconds = Dictionary(uniqueKeysWithValues: timings)
        #expect(seconds["open the log"]! < 2)
        #expect(seconds["first page (200)"]! < 1)
        #expect(seconds["next page (200)"]! < 1)
        #expect(seconds["menu (10 newest)"]! < 0.5)
    }
}
