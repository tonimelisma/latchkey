import Foundation
import Testing

@testable import Latchkey

/// Latchkey's own log for Claude (spec 001 FR-662 to FR-665, contracts/mcp-surface.md
/// "latchkey_log").
@Suite struct LatchkeyLogTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let noon = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-02 12:00:00 UTC

    static func text(_ r: ToolResult) -> String { r.plainText }

    /// An activity log with the app's events in it, written through EventLog as the app does.
    @MainActor static func store(_ write: (EventLog) -> Void) throws -> TraceStore {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let events = EventLog()
        events.attach { try trace.record($0) }
        write(events)
        return trace
    }

    @MainActor static func answer(
        _ trace: TraceStore, _ args: JSONValue = .object([:]), memory: EventLog = EventLog()
    ) -> ToolResult {
        LatchkeyLog.answer(
            args, source: LatchkeyLog.reading(trace.reader), fallback: LatchkeyLog.memory(memory), zone: utc,
            version: "1.2.3")
    }

    /// FR-663: only lines macOS's log has in public; never one recorded with `systemLog: false`,
    /// never Claude's own calls.
    @MainActor @Test func onlyThePublicLinesNeverPrivateOnesOrClaudesCalls() throws {
        let trace = try Self.store { e in
            e.record(.connection, "Connected", at: Self.noon)
            e.record(.pairing, "Paired with https://relay.example as dev-1", systemLog: false, at: Self.noon + 1)
            e.record(.leftovers, "Claude made the file secret-plan.txt", systemLog: false, at: Self.noon + 2)
            e.record(.keepAwake, "Keep-awake on", at: Self.noon + 3)
        }
        try trace.record(
            Activity(
                at: Self.noon + 4, tool: "notes_read", arguments: #"{"title":"Diary"}"#, result: "Dear diary",
                isError: false, durationMS: 3))
        let r = Self.answer(trace)
        #expect(!r.isError)
        let t = Self.text(r)
        #expect(t.contains("Connected"))
        #expect(t.contains("Keep-awake on"))
        #expect(!t.contains("relay.example"))
        #expect(!t.contains("secret-plan"))
        #expect(!t.contains("notes_read"))
        #expect(!t.contains("Diary"))
    }

    /// Entries from before this tool don't say whether they were public, so none is shown.
    @MainActor @Test func eventsFromBeforeTheMarkAreLeftOut() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        var old = Activity.event(.app, "Started 0.8.100, paired with https://relay.example", at: Self.noon)
        old.inSystemLog = nil
        try trace.record(old)
        try trace.record(.event(.app, "Quit", at: Self.noon + 1))
        let t = Self.text(Self.answer(trace))
        #expect(!t.contains("relay.example"))
        #expect(t.contains("Quit"))
    }

    /// FR-664: the newest lines, newest last, one line each: time, category, error mark, text.
    @MainActor @Test func newestLinesLastInTheMacsTimeZone() throws {
        let trace = try Self.store { e in
            for i in 1...5 { e.record(.connection, "line \(i)", error: i == 5, at: Self.noon + Double(i)) }
        }
        let t = Self.text(Self.answer(trace, .object(["lines": .number(2)])))
        let lines = t.split(separator: "\n").map(String.init)
        #expect(lines.contains("2026-11-02 12:00:04 connection: line 4"))
        #expect(lines.contains("2026-11-02 12:00:05 connection ERROR: line 5"))
        #expect(!t.contains("line 3"))
        let four = try #require(lines.firstIndex { $0.hasSuffix("line 4") })
        let five = try #require(lines.firstIndex { $0.hasSuffix("line 5") })
        #expect(four < five)
        #expect(t.contains("1.2.3"))
        #expect(t.contains("UTC"))
    }

    @MainActor @Test func oneCategoryOnly() throws {
        let trace = try Self.store { e in
            e.record(.connection, "Connected", at: Self.noon)
            e.record(.power, "Woke", at: Self.noon + 1)
        }
        let t = Self.text(Self.answer(trace, .object(["category": .string("power")])))
        #expect(t.contains("Woke"))
        #expect(!t.contains("Connected"))
    }

    @MainActor @Test func badArgumentsAreRefusedPlainly() throws {
        let trace = try Self.store { _ in }
        for args: JSONValue in [
            .object(["lines": .number(0)]), .object(["lines": .number(1001)]), .object(["lines": .number(2.5)]),
            .object(["category": .string("leftovers")]), .object(["category": .string("nonsense")]),
        ] {
            #expect(Self.answer(trace, args).isError, "\(args.jsonText)")
        }
        #expect(LatchkeyLog.categories.contains("connection"))
        #expect(!LatchkeyLog.categories.contains("leftovers"))
    }

    /// A line's text that holds a line break stays one line.
    @MainActor @Test func oneLineEach() throws {
        let trace = try Self.store { e in e.record(.app, "first\nsecond", at: Self.noon) }
        #expect(Self.text(Self.answer(trace)).contains("app: first second"))
    }

    @MainActor @Test func nothingYetSaysSo() throws {
        let trace = try Self.store { _ in }
        let r = Self.answer(trace, .object(["category": .string("helper")]))
        #expect(!r.isError)
        #expect(Self.text(r).contains("no helper lines"))
    }

    /// The answer stays within one tool result's size: the oldest lines go, and it says so.
    @MainActor @Test func keepsWithinTheAnswersSize() throws {
        let long = String(repeating: "x", count: 900)
        let trace = try Self.store { e in
            for i in 1...100 { e.record(.app, "\(i) \(long)", at: Self.noon + Double(i)) }
        }
        let t = Self.text(Self.answer(trace, .object(["lines": .number(100)])))
        #expect(t.count <= ResultLimit.characters)
        #expect(t.contains("100 \(long)"))
        #expect(!t.contains(" 1 \(long)"))
        #expect(t.contains("left out"))
    }

    /// Without the activity log at this launch, this launch's public lines from memory.
    @MainActor @Test func withoutTheActivityLogThisLaunchsLines() {
        let events = EventLog()
        events.discard()
        events.record(.connection, "Connected", at: Self.noon)
        events.record(.pairing, "Paired with https://relay.example", systemLog: false, at: Self.noon + 1)
        let r = LatchkeyLog.answer(
            .object([:]), source: nil, fallback: LatchkeyLog.memory(events), zone: Self.utc, version: "1.2.3")
        let t = Self.text(r)
        #expect(!r.isError)
        #expect(t.contains("Connected"))
        #expect(!t.contains("relay.example"))
        #expect(t.contains("since Latchkey started"))
    }

    /// In memory, at most the most lines one answer can ask for.
    @Test func memoryKeepsTheNewestLines() {
        let events = EventLog()
        events.discard()
        for i in 1...(LatchkeyLog.maxLines + 5) { events.record(.app, "line \(i)", at: Self.noon + Double(i)) }
        let kept = events.shown(category: nil, limit: .max)
        #expect(kept.count == LatchkeyLog.maxLines)
        #expect(kept.first?.result == "line \(LatchkeyLog.maxLines + 5)")
    }

    /// FR-662: offered whatever the capabilities' levels, and read-only.
    @MainActor @Test func offeredWithEveryCapabilityOff() async throws {
        let trace = try Self.store { e in e.record(.connection, "Connected", at: Self.noon) }
        let source = LatchkeyLog.reading(trace.reader)
        let registry = CapabilityRegistry(
            capabilities: AppModel.makeCapabilities(),
            levels: CapabilityRegistry.defaultLevels.mapValues { _ in .off },
            always: [LatchkeyLog.entry(source: source, fallback: LatchkeyLog.memory(EventLog()))])
        #expect(registry.tools.map(\.name) == ["latchkey_log"])
        #expect(registry.tools.first?.annotations?.readOnlyHint == true)
        #expect(!registry.anyOn)
        let r = await registry.call(tool: "latchkey_log", arguments: .object([:]))
        #expect(Self.text(r).contains("Connected"))
        try AgentMessage.validate(tools: registry.tools)
    }
}
