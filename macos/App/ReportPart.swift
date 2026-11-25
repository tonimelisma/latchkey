import CoreGraphics
import Foundation
import SystemConfiguration

/// This Mac's part of a problem report (spec 014 FR-1443 to FR-1447): the relay asks for it with
/// a call of a tool no machine lists (`tool`), only while the Owner shares problem reports; the
/// answer is one text holding the part's JSON (contract feedback-intake.md). Not one of Claude's
/// calls: answered before the capabilities, logged as an event, not in the trace.
enum ReportPart {
    static let tool = "latchkey_report_part"
    /// Announced in hello, so only a relay that knows the tool asks (agent-protocol.md).
    static let feature = "report_part"
    static let maxBytes = 3_500_000
    /// The relay waits 10 s for a part; pages get what is left after the log.
    static let pagesLimit: Duration = .seconds(7)

    struct Args: Codable, Sendable {
        var report: String?
        // Milliseconds; read as Double, so a time with a fraction is read too (a test found it).
        var since: Double
        var until: Double
        var callIDs: [String]?
        var pages: [String]?
        var maxBytes: Int?
        enum CodingKeys: String, CodingKey {
            case report, since, until, callIDs = "call_ids", pages, maxBytes = "max_bytes"
        }
    }

    struct LogLine: Codable, Sendable, Equatable {
        var time: String
        var category: String
        var error: Bool?
        var text: String
    }

    struct CallCopy: Codable, Sendable {
        var callID: String
        var time: String
        var tool: String
        var result: JSONValue?
        var isError: Bool?
        var durationMS: Int
        enum CodingKeys: String, CodingKey {
            case callID = "call_id", time, tool, result, isError = "is_error", durationMS = "duration_ms"
        }
    }

    struct Part: Codable, Sendable {
        var log: [LogLine] = []
        var calls: [CallCopy] = []
        var pages: [JSONValue] = []
        var notes: [String] = []
        /// Names the relay replaces in the report and never sends (FR-1449).
        var privateNames: [String] = []
        /// Values Claude typed into password and code fields, for the relay to blank; never sent,
        /// never left out for size (FR-1448).
        var secrets: [String] = []
        enum CodingKeys: String, CodingKey {
            case log, calls, pages, notes, privateNames = "private", secrets
        }
    }

    /// This Mac's names (its computer name and local host name), the Owner's login name and home
    /// folder (FR-1449). From the system's settings, not `ProcessInfo.hostName`, which may wait on
    /// a network lookup.
    static func privateNames() -> [String] {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let local = SCDynamicStoreCopyLocalHostName(nil) as String?
        return [computer, local, local.map { $0 + ".local" }, NSUserName(), NSHomeDirectory()]
            .compactMap { $0 }.filter { $0.count >= 3 }
    }

    /// The activity log's entries from one moment to another, oldest first.
    typealias Entries = @Sendable (_ from: Date, _ to: Date) throws -> [Activity]
    /// The chat's pages as they are, and notes on those that couldn't be described.
    struct Described: Sendable {
        var pages: [JSONValue]
        var notes: [String]
    }
    typealias Pages = @Sendable (_ names: [String]) async -> Described

    /// Only while the Owner shares problem reports, the relay doesn't block them, and Claude's
    /// access isn't paused; the Mac checks its own setting, not only the relay's (security review
    /// 2026-11-25).
    static func refusal(sharing: Bool, blocked: Bool, paused: Bool) -> ToolResult? {
        sharing && !blocked && !paused ? nil : .text("This Mac doesn't share problem reports now.", isError: true)
    }

    /// `readLimit`: how long the activity log may take (tests on a busy runner give more).
    static func answer(
        _ arguments: JSONValue, entries: Entries?, readLimit: Duration = .seconds(3), secrets: [String] = [],
        pages: @escaping Pages
    ) async -> ToolResult {
        guard let data = try? JSONEncoder().encode(arguments),
            let args = try? JSONDecoder().decode(Args.self, from: data)
        else { return .text("The request for this Mac's part couldn't be read.", isError: true) }
        guard args.since.isFinite, args.until.isFinite else {
            return .text("The request for this Mac's part has no usable times.", isError: true)
        }
        var to = Date(timeIntervalSince1970: args.until / 1000)
        var from = Date(timeIntervalSince1970: args.since / 1000)
        if to < from || to.timeIntervalSince(from) > 48 * 3600 { from = to.addingTimeInterval(-48 * 3600) }
        to = to.addingTimeInterval(1)
        var part = Part()
        part.privateNames = privateNames()
        part.secrets = secrets
        if let entries {
            // Off the shared pool, behind a limit (.claude/rules/macos.md: never block a thread in
            // async code; security review 2026-11-25).
            let span = (from, to)
            let read: Result<[Activity], ReadFailure>? = await Deadline.first(within: readLimit) {
                await withCheckedContinuation { (c: CheckedContinuation<Result<[Activity], ReadFailure>?, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        do { c.resume(returning: .success(try entries(span.0, span.1))) } catch {
                            c.resume(returning: .failure(ReadFailure(text: error.localizedDescription)))
                        }
                    }
                }
            }
            do {
                guard let read else { throw ReadFailure(text: "it took longer than \(readLimit)") }
                let ids = Set(args.callIDs ?? [])
                for a in try read.get().sorted(by: { $0.at < $1.at }) {
                    let time = PageRecord.iso8601(a.at)
                    if a.kind == .event, a.inSystemLog == true {  // only what latchkey_log shows (FR-663)
                        part.log.append(
                            LogLine(time: time, category: a.tool, error: a.isError ? true : nil, text: a.result))
                    } else if a.kind == .action, let id = a.callID, ids.contains(id) {
                        let result = try? JSONDecoder().decode(JSONValue.self, from: Data(a.result.utf8))
                        part.calls.append(
                            CallCopy(
                                callID: id, time: time, tool: a.tool, result: result ?? .string(a.result),
                                isError: a.isError ? true : nil, durationMS: a.durationMS))
                    }
                }
            } catch let f as ReadFailure {
                part.notes.append("the activity log couldn't be read: \(f.text)")
            } catch {
                part.notes.append("the activity log couldn't be read: \(error.localizedDescription)")
            }
        } else {
            part.notes.append("the activity log isn't open")
        }
        let names = args.pages ?? []
        if !names.isEmpty {
            if let found = await Deadline.first(within: pagesLimit, { await pages(names) }) {
                part.pages = found.pages
                part.notes += found.notes
            } else {
                part.notes.append("the pages didn't answer within \(Int(pagesLimit.components.seconds)) seconds")
            }
        }
        guard let text = fit(part, maxBytes: min(args.maxBytes ?? maxBytes, maxBytes)) else {
            return .text("This Mac's part doesn't fit in the size the relay asked for.", isError: true)
        }
        return .text(text)
    }

    /// The part as JSON text of at most `maxBytes`: the oldest calls' copies go first, then the
    /// oldest log lines, then the pages' screenshots, then page sources.
    static func fit(_ part: Part, maxBytes: Int) -> String? {
        var part = part
        let note = "some of the oldest was left out (size)"
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        while true {
            guard let data = try? enc.encode(part) else { return nil }
            if data.count <= maxBytes { return String(decoding: data, as: UTF8.self) }
            if !part.notes.contains(note) { part.notes.append(note) }
            if let i = part.calls.firstIndex(where: { $0.result != nil }) {
                part.calls[i].result = nil
            } else if !part.log.isEmpty {
                part.log.removeFirst((part.log.count + 1) / 2)
            } else if let i = part.pages.firstIndex(where: { $0["screenshot"] != nil }),
                case .object(var p) = part.pages[i]
            {
                p["screenshot"] = nil
                part.pages[i] = .object(p)
            } else if let i = part.pages.firstIndex(where: { $0["source"] != nil }),
                case .object(var p) = part.pages[i]
            {
                p["source"] = nil
                p["source_cut"] = .bool(true)
                part.pages[i] = .object(p)
            } else if !part.pages.isEmpty {
                part.pages.removeFirst()
            } else if !part.calls.isEmpty {
                part.calls.removeFirst()
            } else {
                return nil
            }
        }
    }

    struct ReadFailure: Error, Sendable {
        var text: String
    }

    /// Whether the main display is asleep, for the pages' drawing state.
    static func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}
