import CryptoKit
import Foundation
import Testing

@testable import Latchkey

/// No call goes missing from the activity log because the app stopped while it ran (spec 001
/// FR-666 to FR-668): a quit records each running call as cut off, a crash leaves a sealed mark
/// that the next start records, and the comparison tells a call an older app's quit cut off
/// from a real gap.
@Suite struct CutOffCallsTests {
    static let device = "dev_8f3kq2m7xz"

    static func mark(_ n: Int, at: Date = Date(timeIntervalSince1970: 1_793_200_000)) -> CallMark {
        CallMark(
            callID: "call_CUT\(n)", at: at, tool: "mail_find", arguments: "{\"query\":\"invoice \(n)\"}",
            device: device, client: "Claude Code")
    }

    static func marks(_ dir: URL, key: SymmetricKey = SymmetricKey(size: .bits256)) -> CallMarks {
        CallMarks(directory: dir.appending(path: "Running calls", directoryHint: .isDirectory), key: key)
    }

    // MARK: the marks on disk (FR-667)

    /// A running call's mark is sealed (no tool, arguments, or app name in the clear), read back
    /// whole, and gone once removed.
    @Test func aMarkIsSealedAndRemoved() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marks = Self.marks(dir)
        try marks.write(Self.mark(1))
        let files = try FileManager.default.contentsOfDirectory(at: marks.directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: files[0])
        for clear in ["mail_find", "invoice", "Claude Code", Self.device] {
            #expect(bytes.range(of: Data(clear.utf8)) == nil, "\(clear) is in the clear")
        }
        #expect(marks.leftovers().marks == [Self.mark(1)])
        marks.remove("call_CUT1")
        #expect(marks.leftovers().marks.isEmpty)
    }

    /// A mark that can't be opened (another key, or damaged) is counted and removed, never
    /// recorded as a call.
    @Test func anUnreadableMarkIsCountedAndRemoved() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.marks(dir).write(Self.mark(1))
        let other = Self.marks(dir)  // another key
        let found = other.leftovers()
        #expect(found.marks.isEmpty && found.unreadable == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.directory.path).isEmpty)
    }

    // MARK: quit (FR-666)

    /// Calls still running when the app quits are recorded as cut off by the quit, with their call
    /// id, tool, and start; their marks go; and a call that ends after the quit isn't recorded again.
    @MainActor @Test func aQuitRecordsEachRunningCallAsCutOff() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let marks = Self.marks(dir)
        let calls = CallsInFlight(marks: marks)
        let started = Date(timeIntervalSince1970: 1_793_200_000)
        calls.begin(Self.mark(1, at: started))
        calls.begin(Self.mark(2, at: started))
        #expect(calls.end("call_CUT2"))  // finished normally before the quit
        calls.recorded("call_CUT2")
        #expect(calls.quitLine == "Quitting with 1 call running; it is recorded as cut off by the quit")
        let n = calls.recordQuit(now: started.addingTimeInterval(3)) { try trace.record($0) }
        #expect(n == 1)
        let stored = try trace.reader.page(ActivityQuery(kind: .action), limit: 10).entries
        #expect(stored.count == 1)
        let entry = try #require(stored.first)
        #expect(entry.callID == "call_CUT1" && entry.tool == "mail_find" && entry.device == Self.device)
        #expect(entry.at == started && entry.durationMS == 3000 && entry.isError)
        #expect(entry.client == "Claude Code")
        #expect(entry.result.contains(CallsInFlight.cutOffByQuit))
        #expect(marks.leftovers().marks.isEmpty)
        #expect(!calls.end("call_CUT1"), "the quit recorded it already")
        #expect(calls.quitLine == "Quitting with no calls running")
    }

    // MARK: crash or kill (FR-667)

    /// A mark left by an app that stopped without quitting is recorded at the next start as ended
    /// by the app stopping, once, and never for a call the log already has.
    @MainActor @Test func theNextStartRecordsCallsLeftRunning() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let trace = try TraceStore(inMemory: true, keys: keys)
        let marks = Self.marks(dir, key: trace.reader.key)
        try marks.write(Self.mark(1))
        try marks.write(Self.mark(2))
        // Call 2's entry was written just before the app was killed, its mark not yet removed.
        try trace.record(
            Activity(
                at: Self.mark(2).at, tool: "mail_find", arguments: "{}", result: "[]", isError: false, durationMS: 5,
                callID: "call_CUT2", device: Self.device))
        let n = CallsInFlight.recover(marks: marks, logged: { try trace.reader.logged($0) }) {
            try trace.record($0)
        }
        #expect(n == 1)
        let stored = try trace.reader.page(ActivityQuery(kind: .action), limit: 10, oldestFirst: true).entries
        #expect(stored.compactMap(\.callID).sorted() == ["call_CUT1", "call_CUT2"])
        let recovered = try #require(stored.first { $0.callID == "call_CUT1" })
        #expect(recovered.isError && recovered.result.contains(CallsInFlight.endedByStop))
        #expect(recovered.at == Self.mark(1).at && recovered.tool == "mail_find")
        #expect(marks.leftovers().marks.isEmpty)
        #expect(
            CallsInFlight.recover(marks: marks, logged: { try trace.reader.logged($0) }) { try trace.record($0) } == 0)
    }

    // MARK: the comparison (FR-668)

    static let now = Date(timeIntervalSince1970: 1_793_300_000)

    static func relay(_ id: String, minutesAgo: Double, seconds: Double, _ outcome: AuditOutcome = .error)
        -> AuditEntry
    {
        AuditEntry(
            callID: id, at: Int64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000), tool: "mail_find",
            outcome: outcome, durationMS: Int64(seconds * 1000))
    }

    static func mac(_ id: String, minutesAgo: Double) -> MacCall {
        MacCall(callID: id, device: device, at: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// The historical case: an app from before FR-666 quit while the relay's call ran, and the
    /// relay recorded the call ending with the connection. It is named on its own, not missing.
    @Test func aCallAnOlderAppsQuitCutOffIsToldApart() {
        let cut = Self.relay("call_KBYG", minutesAgo: 30, seconds: 4)
        let quit = cut.date.addingTimeInterval(2)
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", minutesAgo: 40, seconds: 1, .ok), cut],
            mac: [Self.mac("call_A", minutesAgo: 40)], macWithoutIDs: 0, device: Self.device, now: Self.now,
            oldQuits: [quit])
        #expect(c.allMatch)
        #expect(c.missingOnMac.isEmpty)
        #expect(c.cutOffByOldQuit.map(\.callID) == ["call_KBYG"])
        #expect(
            c.summary(tools: [:])
                == "Audit check: all 1 call matches; 1 call not on the Mac because Latchkey quit during it, before it recorded such calls: call_KBYG (mail_find, 2026-10-29T18:23:20Z)"
        )
    }

    /// Only a call that was running at the quit, and that didn't end with an answer, is told
    /// apart; a quit at another time or a call the Mac answered stays missing.
    @Test func otherGapsStayMissing() {
        let early = Self.relay("call_EARLY", minutesAgo: 30, seconds: 4)
        let answered = Self.relay("call_OK", minutesAgo: 20, seconds: 4, .ok)
        let c = AuditComparison.compare(
            relay: [early, answered], mac: [], macWithoutIDs: 0, device: Self.device, now: Self.now,
            oldQuits: [early.date.addingTimeInterval(60), answered.date.addingTimeInterval(1)])
        #expect(c.cutOffByOldQuit.isEmpty)
        #expect(c.missingOnMac.map(\.callID) == ["call_EARLY", "call_OK"])
        #expect(!c.allMatch)
    }

    /// The window a quit must fall in: from just before the call started to just after the relay
    /// recorded its end.
    @Test func theQuitWindowSpansTheCall() {
        let r = Self.relay("call_W", minutesAgo: 30, seconds: 10)
        let w = AuditComparison.quitWindow(r)
        #expect(w.contains(r.date) && w.contains(r.date.addingTimeInterval(10)))
        #expect(!w.contains(r.date.addingTimeInterval(-10)) && !w.contains(r.date.addingTimeInterval(20)))
    }

    /// Only an older app's quit counts: its event said just "Quitting". This app's quit line,
    /// whatever it says, never excuses a gap, and neither does another event.
    @MainActor @Test func onlyAnOlderAppsQuitEventCounts() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let t = Date(timeIntervalSince1970: 1_793_200_000)
        try trace.record([
            .event(.app, "Quitting", at: t),
            .event(.app, CallsInFlight(marks: nil).quitLine, at: t.addingTimeInterval(1)),
            .event(.connection, "Quitting", at: t.addingTimeInterval(2)),
            .event(.app, "Quitting", at: t.addingTimeInterval(600)),
        ])
        let found = try trace.reader.oldQuits(in: [t.addingTimeInterval(-5)...t.addingTimeInterval(5)])
        #expect(found == [t])
        #expect(!CallsInFlight(marks: nil).quitLine.isEmpty && CallsInFlight(marks: nil).quitLine != "Quitting")
    }
}
