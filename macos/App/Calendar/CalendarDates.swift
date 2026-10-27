import Foundation

/// Dates as Claude writes and reads them, in the Mac's time zone unless an offset is given
/// (spec 007 FR-744; research.md "Dates in and out").
enum CalendarDates {
    struct Parsed: Equatable, Sendable {
        var date: Date
        /// Written as a day only (`2026-10-27`): an all-day date, or the start of that day.
        var dateOnly: Bool
    }

    static let accepted = "YYYY-MM-DD, or YYYY-MM-DDTHH:MM in the Mac's time zone (optionally with Z or ±HH:MM)"

    static func parse(_ text: String, zone: TimeZone = .current) throws -> Parsed {
        let s = text.trimmingCharacters(in: .whitespaces)
        let pattern = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?(Z|[+-]\d{2}:?\d{2})?$/
        guard let m = s.wholeMatch(of: pattern) else {
            throw ArgumentError(message: "“\(text)” isn't a date Latchkey reads. Use \(accepted).")
        }
        var tz = zone
        if let offset = m.7 {
            tz = offset == "Z" ? TimeZone(identifier: "UTC")! : try Self.zone(offset: String(offset), text)
        }
        var c = DateComponents()
        c.year = Int(m.1)
        c.month = Int(m.2)
        c.day = Int(m.3)
        c.hour = m.4.flatMap { Int($0) } ?? 0
        c.minute = m.5.flatMap { Int($0) } ?? 0
        c.second = m.6.flatMap { Int($0) } ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        // A day that doesn't exist (2026-02-30) is refused; a time skipped when clocks go forward
        // moves on, as Calendar does.
        guard c.hour! < 24, c.minute! < 60, c.second! < 60, let date = cal.date(from: c),
            cal.component(.day, from: date) == c.day, cal.component(.month, from: date) == c.month
        else {
            throw ArgumentError(message: "“\(text)” isn't a date that exists.")
        }
        return Parsed(date: date, dateOnly: m.4 == nil)
    }

    private static func zone(offset: String, _ text: String) throws -> TimeZone {
        let digits = offset.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)), h <= 14, mm < 60,
            let tz = TimeZone(secondsFromGMT: (offset.hasPrefix("-") ? -1 : 1) * (h * 3600 + mm * 60))
        else { throw ArgumentError(message: "“\(text)” has an offset Latchkey can't read.") }
        return tz
    }

    /// The argument under `key`, parsed, or nil when it's missing or empty.
    static func argument(_ args: JSONValue, _ key: String, zone: TimeZone = .current) throws -> Parsed? {
        guard let s = args[key]?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try parse(s, zone: zone)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// `Tue 2026-10-27 15:00`, or `Tue 2026-10-27` for a day.
    static func format(_ d: Date, day: Bool = false, zone: TimeZone = .current) -> String {
        formatter(day ? "EEE yyyy-MM-dd" : "EEE yyyy-MM-dd HH:mm", zone).string(from: d)
    }

    /// An event's time: `Tue 2026-10-27 15:00–16:00`, `Tue 2026-10-27 22:00 – Wed 2026-10-28 01:00`,
    /// `Tue 2026-10-27 (all day)`, `Tue 2026-10-27 – Thu 2026-10-29 (all day)`.
    static func span(_ start: Date, _ end: Date, allDay: Bool, zone: TimeZone = .current) -> String {
        let cal = calendar(zone)
        if allDay {
            // EventKit ends an all-day event at the last day's end (or the next midnight).
            let last = cal.date(byAdding: .second, value: -1, to: max(end, start)) ?? start
            let first = format(start, day: true, zone: zone)
            return cal.isDate(start, inSameDayAs: last)
                ? "\(first) (all day)" : "\(first) – \(format(last, day: true, zone: zone)) (all day)"
        }
        if cal.isDate(start, inSameDayAs: end) {
            return "\(format(start, zone: zone))–\(formatter("HH:mm", zone).string(from: end))"
        }
        return "\(format(start, zone: zone)) – \(format(end, zone: zone))"
    }

    /// The line every answer with times starts with.
    static func zoneLine(_ zone: TimeZone = .current, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let a = abs(seconds)
        let offset = String(format: "UTC%@%02d:%02d", sign, a / 3600, a % 3600 / 60)
        return "Times are in the Mac's time zone, \(zone.identifier) (\(offset))."
    }

    /// `08:00-20:00` as minutes after midnight.
    static func hours(_ text: String?) throws -> (start: Int, end: Int) {
        guard let text, !text.isEmpty else { return (8 * 60, 20 * 60) }
        guard
            let m = text.trimmingCharacters(in: .whitespaces).wholeMatch(
                of: /^(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})$/),
            let h1 = Int(m.1), let m1 = Int(m.2), let h2 = Int(m.3), let m2 = Int(m.4),
            h1 <= 24, h2 <= 24, m1 < 60, m2 < 60, h1 * 60 + m1 < h2 * 60 + m2, h2 * 60 + m2 <= 24 * 60
        else { throw ArgumentError(message: "hours must look like 08:00-20:00 (start before end).") }
        return (h1 * 60 + m1, h2 * 60 + m2)
    }

    /// Gaps of at least `minutes` between `from` and `to`, inside each day's `hours`, that no
    /// busy interval covers (FR-702).
    static func freeTimes(
        busy: [DateInterval], from: Date, to: Date, minutes: Int, hours: (start: Int, end: Int),
        zone: TimeZone = .current
    ) -> [DateInterval] {
        let cal = calendar(zone)
        let merged = busy.sorted { $0.start < $1.start }.reduce(into: [DateInterval]()) { acc, b in
            if let last = acc.last, b.start <= last.end {
                acc[acc.count - 1] = DateInterval(start: last.start, end: max(last.end, b.end))
            } else {
                acc.append(b)
            }
        }
        var free: [DateInterval] = []
        var day = cal.startOfDay(for: from)
        while day < to {
            let open = max(from, cal.date(byAdding: .minute, value: hours.start, to: day)!)
            let close = min(to, cal.date(byAdding: .minute, value: hours.end, to: day)!)
            var cursor = open
            for b in merged where b.end > open && b.start < close {
                if b.start > cursor { free.append(DateInterval(start: cursor, end: b.start)) }
                cursor = max(cursor, b.end)
            }
            if close > cursor { free.append(DateInterval(start: cursor, end: close)) }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return free.filter { $0.duration >= Double(minutes) * 60 }
    }
}

/// One occurrence of an event: EventKit's identifier is shared by every occurrence of a
/// repeating event, so the start is part of the id (research.md "Event ids").
enum EventID {
    static func make(_ identifier: String, start: Date) -> String {
        "\(identifier)@\(Int(start.timeIntervalSince1970.rounded()))"
    }

    /// The identifier and, when the id names one occurrence, its start.
    static func split(_ id: String) -> (identifier: String, start: Date?) {
        guard let at = id.lastIndex(of: "@"), let seconds = Int(id[id.index(after: at)...]) else { return (id, nil) }
        return (String(id[..<at]), Date(timeIntervalSince1970: Double(seconds)))
    }
}
