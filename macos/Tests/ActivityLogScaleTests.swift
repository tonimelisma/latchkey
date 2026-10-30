import Foundation
import Testing

@testable import Latchkey

/// A large log (FR-614, FR-616): 30,000 generated entries on disk, about 1 KB each. Prints
/// how long each step takes. Fails on a step slow enough for the Owner to notice, on work the
/// window waits for that grows with the log, and on the main thread being held up while the
/// whole-log work runs.
///
/// Why it is built this way (2026-10-29, after it failed once in a full run on 2026-10-28):
/// - Steps that must not grow with the log are timed best of three, so a moment of load from
///   the tests running alongside doesn't count; their limits are 20 to 100 times what they take.
/// - The tamper check is timed at 6,000 and at 30,000 entries: five times the entries may take
///   about five times as long, not 25 (it did grow with the square of the log until 2026-10-29).
/// - The whole-log steps run off the main thread, as in the app, and recording yields between
///   batches, so the main thread isn't held for half a minute while other tests wait for it.
@Suite(.serialized) struct ActivityLogScaleTests {
    /// 30,000 shows the check growing with the log (5 times the entries, about 5 times the time;
    /// its square would be 25 times) as well as 100,000 did, in a third of the time (2026-10-29).
    static let count = 30_000

    static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    @MainActor @Test func aLargeLog() async throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        var timings: [(String, Double)] = []
        /// Best of three: what the step costs, not what the other tests cost it.
        func best<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            var value: T?
            var fastest = Double.infinity
            for _ in 0..<3 { fastest = min(fastest, try Self.seconds { value = try body() }) }
            timings.append((name, fastest))
            return value!
        }
        func once<T: Sendable>(_ name: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
            let start = Date()
            let value = try await Task.detached { try body() }.value
            timings.append((name, Date().timeIntervalSince(start)))
            return value
        }

        let start = Date().addingTimeInterval(-Double(Self.count) * 600)  // one every 10 minutes: ~2 years
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 36)  // ~1 KB
        var checkAtFifth = 0.0
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            let recording = Date()
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
                await Task.yield()  // other tests' main-thread work goes on meanwhile
                if chunk + 1000 == 6_000 {
                    let reader = trace.reader
                    let expected = trace.expected
                    var fastest = Double.infinity
                    for _ in 0..<2 {
                        let t = try await Task.detached {
                            try Self.seconds { _ = try reader.check(expected: expected) }
                        }.value
                        fastest = min(fastest, t)
                    }
                    checkAtFifth = fastest
                }
            }
            timings.append(("record 30k (batches of 1,000)", Date().timeIntervalSince(recording)))
        }
        let trace = try best("open the log") { try TraceStore(directory: dir, keys: keys, latest: latest) }
        let reader = trace.reader
        let expected = trace.expected
        let first = try best("first page (200)") { try reader.page(ActivityQuery(), limit: 200) }
        #expect(first.entries.count == 200)
        #expect(first.unreadable == 0)
        let second = try best("next page (200)") { try reader.page(ActivityQuery(), after: first.next, limit: 200) }
        #expect(second.entries.first?.durationMS == Self.count - 201)
        _ = try best("menu (10 newest)") { try trace.recent(limit: 10) }

        // The whole-log check, off the main thread as the window runs it; meanwhile the main
        // thread records and reads the menu as the app does after a call, without waiting for it.
        let checking = Task.detached { () throws -> (LogCheck, Double) in
            var check = LogCheck()
            let t = try Self.seconds { check = try reader.check(expected: expected) }
            return (check, t)
        }
        var slowestMainStep = 0.0
        var mainSteps = 0
        while mainSteps < 5 {
            slowestMainStep = max(
                slowestMainStep,
                try Self.seconds {
                    try trace.record(.event(.connection, "connected (scale test)"))
                    _ = try trace.recent(limit: 10)
                })
            mainSteps += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        let (check, checkAtAll) = try await checking.value
        timings.append(("tamper check, 6k entries", checkAtFifth))
        timings.append(("tamper check, 30k entries", checkAtAll))
        timings.append(("main thread step during the check", slowestMainStep))
        #expect(check.broken.isEmpty)
        #expect(check.missingNewer == false)
        #expect(check.beforeCheck == 0)

        let rare = try await once("text search, whole log (1 match)") {
            try reader.page(ActivityQuery(text: "needle-in-the"), limit: 200)
        }
        #expect(rare.entries.map(\.durationMS) == [1234])
        #expect(rare.next == nil)
        let tool = try await once("tool filter, first page") {
            try reader.page(ActivityQuery(tool: "files_read"), limit: 200)
        }
        #expect(tool.entries.count == 200)
        let month = try await once("last 30 days, first page") {
            try reader.page(
                ActivityQuery(from: start.addingTimeInterval(Double(Self.count) * 600 - 30 * 86_400)), limit: 200)
        }
        #expect(month.entries.count == 200)
        let url = dir.appending(path: "export.jsonl")
        let exported = try await once("export whole log") { try reader.export(ActivityQuery(), to: url) }
        #expect(exported == Self.count + mainSteps)
        let disk = trace.diskBytes

        let report =
            timings.map { String(format: "%-36@ %8.3f s", $0.0 as NSString, $0.1) }.joined(separator: "\n")
            + "\nlog on disk: \(ByteCountFormatter.string(fromByteCount: disk, countStyle: .file))"
        print("Activity log, \(Self.count) entries:\n\(report)")
        try? report.write(
            to: FileManager.default.temporaryDirectory.appending(path: "latchkey-activity-scale.txt"), atomically: true,
            encoding: .utf8)
        let took = Dictionary(uniqueKeysWithValues: timings)
        // What the window and the menu wait for: the same for 100 entries or 30,000.
        #expect(took["open the log"]! < 1, "open the log: \(took["open the log"]!) s")
        #expect(took["first page (200)"]! < 0.5, "first page: \(took["first page (200)"]!) s")
        #expect(took["next page (200)"]! < 0.5, "next page: \(took["next page (200)"]!) s")
        #expect(took["menu (10 newest)"]! < 0.25, "menu: \(took["menu (10 newest)"]!) s")
        #expect(slowestMainStep < 0.5, "the main thread waited \(slowestMainStep) s for the check")
        // The check grows with the log, never with its square.
        #expect(
            checkAtAll < 12 * checkAtFifth,
            "tamper check: \(checkAtFifth) s at 6,000 entries, \(checkAtAll) s at 30,000")
    }
}
