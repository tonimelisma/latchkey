import Foundation

/// Latchkey's own recent log, for Claude to find out why something in Latchkey isn't working
/// (spec 001 FR-662 to FR-665, contracts/mcp-surface.md "latchkey_log"). Only the app's own
/// events whose line went to macOS's log in public (FR-620): never one recorded with
/// `systemLog: false` (the relay's address, file names), never Claude's own calls.
enum LatchkeyLog {
    static let name = "latchkey_log"
    static let defaultLines = 200
    static let maxLines = 1000
    /// The longest one line is shown; events are a sentence, so this only guards the answer.
    static let maxLineCharacters = 2000
    /// The categories Claude can ask for. Left Behind entries never go to macOS's log.
    static let categories = EventCategory.allCases.filter { $0 != .leftovers }.map(\.rawValue)

    /// The newest public lines of one category (nil: all), newest first, at most `limit`.
    typealias Source = @Sendable (_ category: String?, _ limit: Int) throws -> [Activity]

    /// From the activity log: kept across launches.
    static func reading(_ reader: ActivityReader) -> Source {
        { category, limit in
            try reader.page(
                ActivityQuery(tool: category, kind: .event, inSystemLogOnly: true), limit: limit,
                countUnreadable: false
            ).entries
        }
    }

    /// From memory: this launch's lines only (FR-665).
    static func memory(_ events: EventLog) -> Source {
        { category, limit in events.shown(category: category, limit: limit) }
    }

    static func entry(
        source: Source?, fallback: @escaping Source, zone: @escaping @Sendable () -> TimeZone = { .current },
        version: String = "?"
    ) -> ToolEntry {
        ToolEntry(
            tool: .make(
                name, title: "Latchkey's Log",
                description: """
                    Latchkey's own recent log on this Mac, for finding out why something in Latchkey isn't \
                    working: its connection to the relay, keep-awake, sleep and wake, macOS permissions, setup, \
                    pause, pairing, and errors it showed. Newest last, one line each: time, category, ERROR \
                    when it was one, text. It holds no tool calls, messages, file names, or the relay's \
                    address. Optional: lines (default \(defaultLines), up to \(maxLines)) and category (one \
                    kind only).
                    """,
                input: [
                    "lines": .integerParam("How many of the newest lines (default \(defaultLines), up to \(maxLines))"),
                    "category": .enumParam(categories, "Only lines of this kind"),
                ], readOnly: true),
            handler: { args in answer(args, source: source, fallback: fallback, zone: zone(), version: version) })
    }

    static func answer(
        _ args: JSONValue, source: Source?, fallback: Source, zone: TimeZone, version: String
    ) -> ToolResult {
        let count: Int
        do {
            count = try args.integer("lines", in: 1...maxLines) ?? defaultLines
        } catch {
            return .text((error as? ArgumentError)?.message ?? "\(error)", isError: true)
        }
        var category: String?
        switch args["category"] {
        case nil, .null?: category = nil
        case .string(let s)? where categories.contains(s): category = s
        case .string(let s)?: return .unknown("category", s, allowed: categories)
        default: return .unknown("category", nil, allowed: categories)
        }
        let thisLaunch = "so these are only the lines since Latchkey started."
        var note: String?
        var found: [Activity]
        if let source {
            do {
                found = try source(category, count)
            } catch {
                note = "Latchkey couldn't read its activity log just now (\(error.localizedDescription)), \(thisLaunch)"
                found = (try? fallback(category, count)) ?? []
            }
        } else {
            note = "Latchkey's activity log isn't available at this launch, \(thisLaunch)"
            found = (try? fallback(category, count)) ?? []
        }
        let kind = category.map { "\($0) " } ?? ""
        guard !found.isEmpty else {
            return .text(
                ["Latchkey's log on this Mac has no \(kind)lines yet.", note].compactMap { $0 }.joined(separator: " "))
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Newest first, as many as fit in one answer (ResultLimit), then put oldest first.
        let room = ResultLimit.characters - 600
        var lines: [String] = []
        var used = 0
        for a in found {
            let line = Self.line(a, format)
            guard used + line.count + 1 <= room else { break }
            lines.append(line)
            used += line.count + 1
        }
        let left = found.count - lines.count
        var head =
            "Latchkey's own \(kind)log on this Mac (Latchkey \(version)): the newest \(lines.count) lines, newest last; times in \(zone.identifier) (\(offset(zone, at: found[0].at)))."
        if let note { head += " " + note }
        var text = head + "\n" + lines.reversed().joined(separator: "\n")
        if left > 0 {
            text += "\n\(left) older lines left out to keep the answer short; ask for fewer lines or one category."
        }
        return .text(text)
    }

    /// "UTC-08:00": the zone's offset at the newest line.
    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return "UTC\(sign)" + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func line(_ a: Activity, _ format: DateFormatter) -> String {
        let flat = a.result.components(separatedBy: .newlines).joined(separator: " ")
        let text = flat.count > maxLineCharacters ? String(flat.prefix(maxLineCharacters)) + "…" : flat
        return "\(format.string(from: a.at)) \(a.tool)\(a.isError ? " ERROR" : ""): \(text)"
    }
}
