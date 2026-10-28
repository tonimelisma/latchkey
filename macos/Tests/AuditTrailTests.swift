import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import Latchkey

/// The log as 0.8.15 to 0.8.23 stored it: the chain's fields, no kind, call id, or device.
enum LogBeforeEvents {
    @Model final class SealedActivity {
        #Index<SealedActivity>([\.at, \.seq], [\.seq], [\.keyID])

        var id: UUID
        var at: Date
        var sealed: Data
        var seq: Int = 0
        var mac: Data?
        var keyID: String = ""

        init(id: UUID, at: Date, sealed: Data, seq: Int, mac: Data?, keyID: String) {
            self.id = id
            self.at = at
            self.sealed = sealed
            self.seq = seq
            self.mac = mac
            self.keyID = keyID
        }
    }

    /// Seals and chains `entries` exactly as those versions did (the checksum over the previous
    /// one, seq, id, time, and key ID), and returns the newest entry's record.
    @MainActor static func write(_ entries: [Activity], key: SymmetricKey, to dir: URL) throws -> Data {
        let reader = ActivityReader(
            container: try ModelContainer(
                for: Latchkey.SealedActivity.self, configurations: .init(isStoredInMemoryOnly: true)),
            key: key)
        let container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(url: dir.appending(path: TraceStore.fileName)))
        var previous = ActivityReader.chainStart
        var seq = 1
        for a in entries {
            var m = Data(previous)
            withUnsafeBytes(of: UInt64(seq).bigEndian) { m.append(contentsOf: $0) }
            m.append(contentsOf: withUnsafeBytes(of: a.id.uuid) { Array($0) })
            withUnsafeBytes(of: a.at.timeIntervalSinceReferenceDate.bitPattern.bigEndian) { m.append(contentsOf: $0) }
            m.append(Data(reader.keyID.utf8))
            let mac = Data(HMAC<SHA256>.authenticationCode(for: m, using: reader.chainKey))
            let sealed = try AES.GCM.seal(
                try JSONEncoder().encode(a), using: key, authenticating: ActivityReader.boundData(seq: seq, id: a.id)
            ).combined!
            container.mainContext.insert(
                SealedActivity(id: a.id, at: a.at, sealed: sealed, seq: seq, mac: mac, keyID: reader.keyID))
            previous = mac
            seq += 1
        }
        try container.mainContext.save()
        return LatestEntryRecord.encode(keyID: reader.keyID, tip: ChainTip(seq: seq - 1, mac: previous))
    }
}

/// The audit trail without gaps (Toni, 2026-10-27): the app's own events in the activity log
/// (FR-633), the relay's call id in each action (FR-632), and the comparison with the relay's
/// audit (FR-634), each shown recorded (FR-636).
@Suite struct AuditTrailTests {
    static let device = "dev_8f3kq2m7xz"

    static func call(_ n: Int, at: Date, device: String = AuditTrailTests.device) -> Activity {
        Activity(
            at: at, tool: "shell_run", arguments: "{\"command\":\"echo \(n)\"}", result: "output \(n)", isError: false,
            durationMS: n, callID: "call_\(n)", device: device)
    }

    // MARK: upgrade

    /// Toni's log (about 19 MB, chained) upgrades in place: every entry stays readable, becomes
    /// an action without a call id, the chain still holds, and new entries continue it.
    @MainActor @Test func upgradesTheLogFromBeforeEvents() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let now = Date()
        let old = (1...5).map { ActivityLogTests.entry($0, at: now.addingTimeInterval(Double($0 - 10) * 60)) }
        let record = try LogBeforeEvents.write(old, key: try keys.loadOrCreate(), to: dir)
        let latest = MemoryLatestEntry(.found(record))

        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            #expect(trace.latestState == .ok)
            let page = try trace.page(limit: 100)
            #expect(page.entries.map(\.result) == ["output 5", "output 4", "output 3", "output 2", "output 1"])
            #expect(
                page.entries.allSatisfy {
                    $0.kind == .action && $0.callID == nil && $0.client == nil && !$0.beforeCheck
                })
            #expect(try trace.reader.check(expected: trace.expected) == LogCheck(), "the old chain still holds")
            try trace.record(Self.call(6, at: now))
            try trace.record(Activity.event(.connection, "Connected to the relay", at: now.addingTimeInterval(1)))
            #expect(latest.writes == ["update", "update"])
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck(), "and continues across the new kinds")
        let page = try trace.page(limit: 100)
        #expect(page.entries.count == 7)
        #expect(page.entries[0].kind == .event)
        #expect(page.entries[1].callID == "call_6")
        #expect(page.entries[1].device == Self.device)
    }

    // MARK: the stored shape

    /// Kind, call id, and device are kept beside the sealed content and covered by the chain:
    /// changing one in the file breaks it there.
    @MainActor @Test func changingAKindOrCallIDIsCaught() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            try trace.record((1...4).map { Self.call($0, at: now.addingTimeInterval(Double($0))) })
        }
        try ActivityLogTests.tamper(dir) { _, rows in rows[1].callID = "call_99" }
        #expect(try ActivityLogTests.check(dir, keys, latest).broken.map(\.seq) == [2])
        try ActivityLogTests.tamper(dir) { _, rows in
            rows[1].callID = "call_2"
            rows[2].kind = ActivityKind.event.rawValue
        }
        #expect(try ActivityLogTests.check(dir, keys, latest).broken.map(\.seq) == [3])
    }

    @MainActor @Test func theMenuShowsClaudesActionsOnlyAndTheWindowFiltersByKind() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let now = Date()
        try trace.record([
            Self.call(1, at: now), .event(.power, "Woke from sleep", at: now.addingTimeInterval(1)),
            Self.call(2, at: now.addingTimeInterval(2)), .event(.app, "Quitting", at: now.addingTimeInterval(3)),
        ])
        #expect(try trace.recent(limit: 10).map(\.result) == ["output 2", "output 1"])
        let events = try trace.reader.page(ActivityQuery(kind: .event), limit: 10).entries
        #expect(events.map(\.result) == ["Quitting", "Woke from sleep"])
        #expect(events.map(\.tool) == ["app", "power"])
        #expect(try trace.reader.page(ActivityQuery(kind: .action), limit: 10).entries.count == 2)
        #expect(try trace.reader.page(ActivityQuery(), limit: 10).entries.count == 4, "both, unfiltered")
        #expect(try trace.reader.page(ActivityQuery(text: "woke"), limit: 10).entries.count == 1, "events are searched")
    }

    /// FR-633, FR-615: Export… carries both kinds, with the kind and the call id.
    @Test func anExportedLineNamesItsKindAndCallID() throws {
        let format = ActivityExport(timeZone: TimeZone(secondsFromGMT: 0)!)
        let action = try #require(
            JSONSerialization.jsonObject(with: Data(format.line(Self.call(1, at: Date())).utf8)) as? [String: Any])
        #expect(action["kind"] as? String == "action")
        #expect(action["call_id"] as? String == "call_1")
        let event = try #require(
            JSONSerialization.jsonObject(with: Data(format.line(.event(.keepAwake, "Keep-awake on", at: Date())).utf8))
                as? [String: Any])
        #expect(event["kind"] as? String == "event")
        #expect(event["call_id"] is NSNull)
        #expect(event["tool"] as? String == "keepawake")
        #expect(event["result"] as? String == "Keep-awake on")
    }

    // MARK: events (FR-633, FR-636)

    /// Every kind of event the app records lands in the log, chained, and survives a restart.
    @MainActor @Test func everyKindOfEventIsRecorded() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            let events = EventLog()
            events.attach { try trace.record($0) }
            for category in EventCategory.allCases {
                events.record(category, "a \(category.rawValue) event", error: category == .helper)
            }
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        let stored = try trace.reader.page(ActivityQuery(kind: .event), limit: 100, oldestFirst: true).entries
        #expect(stored.map(\.tool) == EventCategory.allCases.map(\.rawValue))
        #expect(stored.map(\.result) == EventCategory.allCases.map { "a \($0.rawValue) event" })
        #expect(stored.filter(\.isError).map(\.tool) == ["helper"])
        #expect(try trace.reader.check(expected: trace.expected) == LogCheck())
    }

    /// Events from before the log opened (the start, the first keep-awake decision) are kept and
    /// written in order once it does.
    @MainActor @Test func eventsBeforeTheLogOpensAreKeptInOrder() throws {
        let events = EventLog()
        events.record(.app, "first")
        events.record(.connection, "second")
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        events.attach { try trace.record($0) }
        events.record(.app, "third")
        let stored = try trace.reader.page(ActivityQuery(), limit: 10, oldestFirst: true).entries
        #expect(stored.map(\.result) == ["first", "second", "third"])
    }

    /// A save that fails keeps the events for the next try: nothing is dropped.
    @MainActor @Test func aFailedSaveKeepsTheEvents() throws {
        let events = EventLog()
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let failing = Locked(true)
        events.attach { batch in
            if failing.value { throw CocoaError(.fileWriteUnknown) }
            try trace.record(batch)
        }
        events.record(.app, "one")
        failing.mutate { $0 = false }
        events.record(.app, "two")
        #expect(
            try trace.reader.page(ActivityQuery(), limit: 10, oldestFirst: true).entries.map(\.result) == [
                "one", "two",
            ])
    }

    @MainActor @Test func eventsAreNeverDeletedByAge() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: MemoryLatestEntry())
            try trace.record(.event(.app, "Started 0.1.0", at: now.addingTimeInterval(-20 * 365 * 86_400)))
            try trace.record(Self.call(1, at: now.addingTimeInterval(-10 * 365 * 86_400)))
            try trace.record(.event(.app, "Started 9.9.9", at: now))
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: MemoryLatestEntry())
        #expect(try trace.reader.page(ActivityQuery(), limit: 10).entries.count == 3)
    }

    /// No code in the app deletes activity entries (FR-636): uninstall removes the whole file,
    /// nothing else removes a row.
    @Test func noCodeDeletesActivityEntries() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App")
            .standardizedFileURL
        let files = try FileManager.default.subpathsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("delete(model:"), "\(file)")
            #expect(!text.contains("context.delete("), "\(file)")
            #expect(!text.contains("modelContext.delete("), "\(file)")
        }
    }

    // MARK: the comparison (FR-634)

    static let now = Date(timeIntervalSince1970: 1_793_200_000)

    static func relay(_ id: String, _ minutesAgo: Double, _ outcome: AuditOutcome = .ok, tool: String = "shell_run")
        -> AuditEntry
    {
        AuditEntry(
            callID: id, at: Int64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000), tool: tool, outcome: outcome,
            durationMS: 5)
    }

    static func mac(_ id: String, _ minutesAgo: Double, device: String = AuditTrailTests.device) -> MacCall {
        MacCall(callID: id, device: device, at: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func allCallsMatch() {
        let c = AuditComparison.compare(
            relay: [
                Self.relay("call_A", 30), Self.relay("call_B", 20, .error), Self.relay("call_C", 10, .timeout),
                Self.relay("call_D", 9, .offline), Self.relay("", 50),
            ],
            mac: [Self.mac("call_A", 30), Self.mac("call_B", 20), Self.mac("call_C", 10)], macWithoutIDs: 2,
            device: Self.device, now: Self.now)
        #expect(c.matched == 3)
        #expect(c.missingOnMac.isEmpty && c.missingOnRelay.isEmpty)
        #expect(c.allMatch)
        #expect(c.beforeCallIDs == 3, "the relay's row without an id and the Mac's two")
        #expect(c.summary(tools: [:]) == "Audit check: all 3 calls match; 3 calls from before call ids left out")
    }

    @Test func aCallMissingOnTheMacIsNamed() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30), Self.relay("call_B", 20, tool: "files_read")],
            mac: [Self.mac("call_A", 30)], macWithoutIDs: 0, device: Self.device, now: Self.now)
        #expect(!c.allMatch)
        #expect(c.missingOnMac.map(\.callID) == ["call_B"])
        #expect(
            c.summary(tools: [:])
                == "Audit check: 1 call matches; missing on the Mac: call_B (files_read, 2026-10-28T14:46:40Z)")
    }

    @Test func aCallMissingOnTheRelayIsNamed() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30)], mac: [Self.mac("call_A", 30), Self.mac("call_Z", 15)],
            macWithoutIDs: 0, device: Self.device, now: Self.now)
        #expect(c.missingOnRelay.map(\.callID) == ["call_Z"])
        #expect(
            c.summary(tools: ["call_Z": "notes_read"])
                == "Audit check: 1 call matches; missing on the relay: call_Z (notes_read, 2026-10-28T14:51:40Z)")
    }

    /// A call still running, or just finished on one side, isn't missing yet.
    @Test func recentCallsAreNotCountedAsMissing() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30), Self.relay("call_R", 0.5, .timeout)],
            mac: [Self.mac("call_A", 30), Self.mac("call_M", 0.2)], macWithoutIDs: 0, device: Self.device,
            now: Self.now)
        #expect(c.allMatch)
        #expect(c.stillRunning == 2)
        #expect(c.summary(tools: [:]) == "Audit check: all 1 call matches; 2 calls still running left out")
    }

    /// Entries of an earlier pairing are in another device's audit on the relay; ids from relays
    /// before global ids ("c_1") can't be compared.
    @Test func earlierPairingsAndOldIDsAreLeftOutAndCounted() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30)],
            mac: [Self.mac("call_A", 30), Self.mac("call_X", 40, device: "dev_old"), Self.mac("c_1", 50)],
            macWithoutIDs: 0, device: Self.device, now: Self.now)
        #expect(c.allMatch)
        #expect(c.otherPairings == 1)
        #expect(c.beforeCallIDs == 1)
        #expect(
            c.summary(tools: [:])
                == "Audit check: all 1 call matches; 1 call from before call ids left out; 1 call from an earlier pairing left out"
        )
    }

    /// A relay can't make the forever-kept event huge (security review, 2026-10-27): at most 20
    /// calls are named per side, and ids and tool names are cut to 64 characters.
    @Test func longGapsAreSummedUpNotListed() {
        let huge = "call_" + String(repeating: "X", count: 5000)
        let relay = (0..<500).map { Self.relay("call_\($0)", 30 + Double($0)) } + [Self.relay(huge, 25)]
        let c = AuditComparison.compare(relay: relay, mac: [], macWithoutIDs: 0, device: Self.device, now: Self.now)
        let text = c.summary(tools: [:])
        #expect(text.contains("and 481 more"))
        #expect(text.count < 5000, "got \(text.count) characters")
        #expect(AuditComparison.clip(String(repeating: "y", count: 500)).count == 64)
        // One "character" can carry thousands of combining marks: the limit is in bytes.
        let zalgo = "e" + String(repeating: "\u{0301}", count: 5000)
        #expect(zalgo.count == 1)
        #expect(AuditComparison.clip(zalgo).utf8.count <= 256)
        #expect(AuditComparison.clip("call_ok") == "call_ok")
    }

    /// Calls the relay made with ids before this Mac's app stored any (the minutes between the
    /// relay's deploy and the app's install, 2026-10-27) are from before call ids on the Mac;
    /// after its first call with an id, everything must match. A wiped log has no id'd calls, so
    /// then everything is compared and the loss shows.
    @Test func relayCallsFromBeforeTheMacStoredIdsAreLeftOut() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_OLD1", 40), Self.relay("call_OLD2", 35), Self.relay("call_A", 30)],
            mac: [Self.mac("call_A", 30)], macWithoutIDs: 0, device: Self.device, now: Self.now)
        #expect(c.allMatch)
        #expect(c.matched == 1)
        #expect(c.beforeCallIDs == 2)
        let wiped = AuditComparison.compare(
            relay: [Self.relay("call_OLD1", 40), Self.relay("call_A", 30)], mac: [], macWithoutIDs: 0,
            device: Self.device, now: Self.now)
        #expect(wiped.missingOnMac.count == 2, "with no id'd call on the Mac, nothing is left out")
        let later = AuditComparison.compare(
            relay: [Self.relay("call_A", 30), Self.relay("call_LOST", 20)], mac: [Self.mac("call_A", 30)],
            macWithoutIDs: 0, device: Self.device, now: Self.now)
        #expect(later.missingOnMac.map(\.callID) == ["call_LOST"], "after the first id'd call, gaps count")
    }

    @Test func bothSidesMissingAreAllNamed() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30), Self.relay("call_B", 25), Self.relay("call_C", 20)],
            mac: [Self.mac("call_A", 30), Self.mac("call_Y", 22)], macWithoutIDs: 0, device: Self.device,
            now: Self.now)
        let text = c.summary(tools: ["call_Y": "shell_run"])
        #expect(text.hasPrefix("Audit check: 1 call matches; missing on the Mac: call_B (shell_run, "))
        #expect(text.contains("call_C (shell_run, "))
        #expect(text.contains("; missing on the relay: call_Y (shell_run, "))
    }

    @Test func notPossibleLinesSayWhy() {
        #expect(AuditFetch.noAnswer.problem == "Audit check not possible: the relay didn't answer")
        #expect(AuditFetch.notConnected.problem == "Audit check not possible: not connected to the relay")
        #expect(AuditFetch.entries([]).problem == nil)
    }

    // MARK: paging (agent-protocol.md "Audit comparison")

    @Test func pagesAreFollowedUntilTheLast() async {
        let a = Self.relay("call_A", 3)
        let b = Self.relay("call_B", 2)
        let c = Self.relay("call_C", 1)
        let asked = Locked([Int64]())
        let fetch = await AuditPaging.fetch { since in
            asked.mutate { $0.append(since) }
            switch since {
            case 0: return AuditPage(id: "a", entries: [a], nextSince: a.at + 1)
            case a.at + 1: return AuditPage(id: "b", entries: [b], nextSince: b.at + 1)
            default: return AuditPage(id: "c", entries: [c], nextSince: nil)
            }
        }
        #expect(asked.value == [0, a.at + 1, b.at + 1])
        guard case .entries(let all) = fetch else { Issue.record("no entries"); return }
        #expect(all.map(\.callID) == ["call_A", "call_B", "call_C"])
    }

    /// Security review, 2026-10-27: a relay's answer can't make the Mac collect without end or
    /// ask again for what it already has.
    /// Call ids are never cut (two long ids could then look alike and hide a gap): one that
    /// isn't `call_` and 1 to 64 letters or digits is refused (security review, 2026-10-27).
    @Test func callIDsHaveOneExactShape() {
        #expect(AuditComparison.isValidCallID("call_7Q2MXK4RZB3N8P5TVWYC6DHJ9F"))
        #expect(AuditComparison.isValidCallID("call_A"))
        for bad in ["c_17", "call_", "call_" + String(repeating: "A", count: 65), "call_A B", "call_é", "CALL_A", ""] {
            #expect(!AuditComparison.isValidCallID(bad), "\(bad)")
        }
        #expect(CallCheck.refusal(callID: "c_17") != nil)
        #expect(CallCheck.refusal(callID: "call_7Q2MXK4RZB3N8P5TVWYC6DHJ9F") == nil)
    }

    @Test func aRelayIdOfTheWrongShapeIsMalformed() async {
        let fetch = await AuditPaging.fetch { _ in
            AuditPage(id: "a", entries: [Self.relay("call_" + String(repeating: "X", count: 5000), 3)], nextSince: nil)
        }
        #expect(fetch == .badAnswer)
    }

    /// The same id twice on either side is a discrepancy, not quietly merged.
    @Test func anIdRecordedTwiceIsReported() {
        let c = AuditComparison.compare(
            relay: [Self.relay("call_A", 30), Self.relay("call_B", 25), Self.relay("call_B", 24)],
            mac: [Self.mac("call_A", 30), Self.mac("call_A", 29), Self.mac("call_B", 25)], macWithoutIDs: 0,
            device: Self.device, now: Self.now)
        #expect(!c.allMatch)
        let text = c.summary(tools: [:])
        #expect(text.contains("recorded twice on the Mac: call_A"))
        #expect(text.contains("listed twice by the relay: call_B"))
    }

    @Test func aPageLargerThanAskedIsMalformed() async {
        let entry = Self.relay("call_A", 3)
        let fetch = await AuditPaging.fetch(limit: 2) { _ in
            AuditPage(id: "a", entries: [entry, entry, entry], nextSince: nil)
        }
        #expect(fetch == .badAnswer)
        #expect(fetch.problem == "Audit check not possible: the relay's answer was malformed")
    }

    @Test func anEntryFromBeforeTheAskedTimeIsMalformed() async {
        let entry = Self.relay("call_A", 3)
        let fetch = await AuditPaging.fetch { since in
            since == 0
                ? AuditPage(id: "a", entries: [entry], nextSince: entry.at + 1)
                : AuditPage(id: "b", entries: [entry], nextSince: nil)  // a replay of the first page
        }
        #expect(fetch == .badAnswer)
    }

    @Test func aNextPageNotAfterTheNewestEntryIsMalformed() async {
        let entry = Self.relay("call_A", 3)
        let fetch = await AuditPaging.fetch { _ in AuditPage(id: "a", entries: [entry], nextSince: entry.at) }
        #expect(fetch == .badAnswer)
    }

    @Test func theEntriesCollectedAreCapped() async {
        let fetch = await AuditPaging.fetch(limit: 2, maxEntries: 3) { since in
            let at = max(since, 1)
            return AuditPage(
                id: "a",
                entries: [
                    AuditEntry(callID: "call_\(at)", at: at, tool: "t", outcome: .ok, durationMS: 1),
                    AuditEntry(callID: "call_\(at)b", at: at, tool: "t", outcome: .ok, durationMS: 1),
                ],
                nextSince: at + 1)
        }
        #expect(fetch == .badAnswer)
    }

    @Test func aPageWithoutAnAnswerEndsTheCheck() async {
        let fetch = await AuditPaging.fetch { since in
            since == 0 ? AuditPage(id: "a", entries: [], nextSince: 5) : nil
        }
        #expect(fetch == .noAnswer)
    }

    /// A relay whose next page doesn't move on would be asked forever.
    @Test func aPageThatDoesNotMoveOnEndsTheCheck() async {
        let count = Locked(0)
        let fetch = await AuditPaging.fetch { since in
            count.mutate { $0 += 1 }
            return AuditPage(id: "a", entries: [], nextSince: since)
        }
        #expect(fetch == .badAnswer)
        #expect(count.value == 1)
    }

    // MARK: protocol

    @Test func helloAnnouncesTheAuditFeature() {
        let hello = Hello.make(
            deviceID: "dev_1", signature: "sig", appVersion: "0.8.24", osVersion: "26.1", tools: [], state: .sample)
        #expect(hello.features == ["clients", "audit"])
    }

    @Test func anAuditAnswerDecodes() throws {
        let message = try AgentMessage.decode(Data(contentsOf: Fixtures.file("valid/audit.json")))
        guard case .audit(let page) = message else { Issue.record("not audit"); return }
        #expect(page.entries.map(\.outcome) == [.ok, .offline])
        #expect(page.entries[0].at == 1_793_160_333_843)
        #expect(page.nextSince == nil)
    }

    // MARK: the Claude app of each call (FR-637)

    @Test func aCallNamesItsClaudeAppOrNot() throws {
        guard case .call(let named) = try AgentMessage.decode(Data(contentsOf: Fixtures.file("valid/call-client.json")))
        else { Issue.record("not a call"); return }
        #expect(named.client == "Claude Code")
        guard case .call(let older) = try AgentMessage.decode(Data(contentsOf: Fixtures.file("valid/call.json")))
        else { Issue.record("not a call"); return }
        #expect(older.client == nil, "a relay from before FR-637 sends none")
    }

    /// The app's name is kept with the entry (sealed with its content), shown, and exported;
    /// entries from before have none.
    @MainActor @Test func theClaudeAppIsKeptShownAndExported() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            var named = Self.call(1, at: now)
            named.client = "Claude Code"
            try trace.record([named, Self.call(2, at: now.addingTimeInterval(1))])
        }
        let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
        let entries = try trace.reader.page(ActivityQuery(), limit: 10, oldestFirst: true).entries
        #expect(entries.map(\.client) == ["Claude Code", nil])
        #expect(try trace.reader.page(ActivityQuery(text: "claude code"), limit: 10).entries.count == 1, "searchable")
        let format = ActivityExport(timeZone: TimeZone(secondsFromGMT: 0)!)
        let line = try #require(
            JSONSerialization.jsonObject(with: Data(format.line(entries[0]).utf8)) as? [String: Any])
        #expect(line["client"] as? String == "Claude Code")
        let none = try #require(
            JSONSerialization.jsonObject(with: Data(format.line(entries[1]).utf8)) as? [String: Any])
        #expect(none["client"] is NSNull)
        #expect(ActivityRow(entries[0]).client == "Claude Code")
    }
}
