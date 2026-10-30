import Foundation
import Testing

@testable import Latchkey

/// A log whose every read waits until the test lets it go, and says which thread it ran on.
final class HeldLog: ActivityLogSource, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var ranOnMain: [String: Bool] = [:]
    private var waitedTooLong = false

    var threads: [String: Bool] { lock.withLock { ranOnMain } }
    var timedOut: Bool { lock.withLock { waitedTooLong } }

    func release(_ count: Int) { for _ in 0..<count { gate.signal() } }

    /// Holds the read the way a read of a large log takes time. Had it run on the main thread,
    /// the test (on the main thread too) could never let it go: it gives up after 10 s.
    private func hold(_ name: String) {
        lock.withLock { ranOnMain[name] = Thread.isMainThread }
        if gate.wait(timeout: .now() + 10) == .timedOut { lock.withLock { waitedTooLong = true } }
    }

    func windowPage(_ query: ActivityQuery, after cursor: ActivityCursor?, limit: Int) throws -> ActivityPage {
        hold("page")
        return ActivityPage(entries: [.event(.app, "Started")])
    }

    func windowCheck(expected: ChainTip?) throws -> LogCheck {
        hold("check")
        return LogCheck(beforeCheck: 3)
    }
}

/// FR-616: the Activity window appears at once; its first page and the tamper check are read
/// in the background, however large the log.
@Suite struct ActivityWindowLoadingTests {
    @MainActor @Test func theWindowsReadsRunOffTheMainThread() async throws {
        let log = HeldLog()
        let page = Task { await ActivityLoading.page(log, ActivityQuery(), after: nil, limit: 200) }
        let check = Task { await ActivityLoading.check(log, expected: nil) }
        // Both reads are under way and held, and the main thread is free meanwhile.
        for _ in 0..<500 where log.threads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.threads.count == 2, "both reads started")
        log.release(2)
        let (loaded, rows) = try #require(await page.value)
        #expect(loaded.entries.count == 1)
        #expect(rows.map(\.summary) == ["Started"])
        #expect(await check.value?.beforeCheck == 3)
        #expect(log.timedOut == false)
        #expect(log.threads == ["page": false, "check": false])
    }

    /// The chain is walked by number alone and other keys' entries are skipped (2026-10-29): a
    /// key's chain still continues and checks out with more than a batch of another key's
    /// entries after it, and those entries break nothing.
    @MainActor @Test func aChainContinuesPastAnotherKeysEntries() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        func entries(_ range: Range<Int>) -> [Activity] {
            range.map {
                Activity(
                    at: Date(timeIntervalSinceNow: Double($0)), tool: "shell_run", arguments: "{}", result: "\($0)",
                    isError: false, durationMS: $0)
            }
        }
        do { try TraceStore(directory: dir, keys: first, latest: latest).record(entries(0..<3)) }
        let other = MemoryTraceKey()
        do {
            let store = try TraceStore(directory: dir, keys: other, latest: MemoryLatestEntry())
            try store.record(entries(3..<203))  // more than the walk's batch of 64
            #expect(try store.reader.check(expected: store.expected).broken.isEmpty)
        }
        #expect(try TraceStore(directory: dir, keys: first, latest: latest).expected?.seq == 3)
        // Without the Keychain's record, the chain continues from the log alone: the first
        // key's newest entry has to be found below the other key's 200.
        let again = try TraceStore(directory: dir, keys: first, latest: MemoryLatestEntry())
        #expect(again.latestState == .missing)
        try again.record(entries(203..<205))
        let check = try again.reader.check(expected: again.expected)
        #expect(check.broken.isEmpty)
        #expect(check.missingNewer == false)
        #expect(try again.reader.page(ActivityQuery(), limit: 300).entries.count == 5)
    }

    /// The window's first page counts the entries under an earlier key (FR-203); the menu, which
    /// doesn't show the count, skips counting (it reads an index of the whole log).
    @MainActor @Test func onlyTheWindowCountsUnreadableEntries() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        func entry(_ n: Int) -> Activity {
            Activity(
                at: Date(timeIntervalSinceNow: Double(n)), tool: "shell_run", arguments: "{}", result: "ok \(n)",
                isError: false, durationMS: n)
        }
        do {
            let earlier = try TraceStore(directory: dir, keys: MemoryTraceKey(), latest: MemoryLatestEntry())
            try earlier.record(entry(-10))
        }
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey(), latest: MemoryLatestEntry())
        try trace.record(entry(0))
        #expect(try trace.reader.page(ActivityQuery(), limit: 200).unreadable == 1)
        #expect(try trace.reader.page(ActivityQuery(), limit: 200, countUnreadable: false).unreadable == 0)
        #expect(try trace.recent(limit: 10).map(\.durationMS) == [0])
    }
}
