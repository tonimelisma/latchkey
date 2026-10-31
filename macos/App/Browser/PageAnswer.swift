import Foundation

/// Claude's answer for a page, as text: not a page script, so kept apart from `PageScripts`,
/// whose splicing rule (only `literal(...)` values) guards what runs in the page.
extension PageScripts {
    /// The most of an answer the list of links, buttons, and fields may take; the page's text
    /// gets the rest of Claude's result size (FR-405; live check 2026-10-29: a Wikipedia
    /// article's 400 links took 31,000 characters on top of 40,000 of text).
    static let elementsBudget = 20_000

    /// Claude's answer for a page, within Claude's result size (FR-405): title and address, the
    /// part of the text from `offset` that fits, where to read on, and the links, buttons, and
    /// fields (within `elementsBudget`; a link on the page's own host shows its path only).
    /// Positions are JavaScript's (UTF-16), as `offset` counts.
    static func answer(_ p: Page) -> String {
        let head = "\(p.title) — \(p.url)\n\(marking)\n\n"
        var lines: [String] = []
        var used = 0
        for e in p.elements {
            var line = "[\(e.ref)] \(e.kind): \(e.label)"
            if let href = e.href { line += " → \(shortHref(href, on: p.url))" }
            if let v = e.value, !v.isEmpty { line += " (now: \(v))" }
            if let c = e.checked { line += c ? " (checked)" : " (not checked)" }
            if used + line.count + 1 > elementsBudget { break }
            lines.append(line)
            used += line.count + 1
        }
        var elements = lines.isEmpty ? "" : "\n\nOn the page:\n" + lines.joined(separator: "\n")
        if lines.count < p.elements.count {
            elements += "\n(\(p.elements.count - lines.count) more not listed; a script can find them.)"
        }
        let room = max(ResultLimit.characters - head.count - elements.count - 160, 1_000)
        var shown = ""
        var count = 0
        var units = 0
        for ch in p.text {
            if count == room { break }
            shown.append(ch)
            count += 1
            units += ch.utf16.count
        }
        var out = head + shown
        // The page reports these: bounded, so a page can't crash Latchkey with a sum that
        // overflows or name an offset past its own text (security review, 2026-10-30).
        let total = min(max(p.total, 0), 1 << 40)
        let start = min(max(p.offset, 0), total)
        let next = min(start + units, total)
        if next < total {
            out += "\n\n(Characters \(start)–\(next) of \(total). Read on with browser_read and offset \(next).)"
        }
        return out + elements
    }

    /// A link's address as Claude needs it: the path alone when it is on the page's own scheme,
    /// host, and port.
    static func shortHref(_ href: String, on page: String) -> String {
        guard let h = URLComponents(string: href), let p = URLComponents(string: page),
            let scheme = h.scheme?.lowercased(), scheme == p.scheme?.lowercased(),
            let host = h.host?.lowercased(), !host.isEmpty, host == p.host?.lowercased(), h.port == p.port,
            h.user == nil, h.percentEncodedPath.hasPrefix("/")
        else { return href }
        var path = h.percentEncodedPath
        if let q = h.percentEncodedQuery { path += "?" + q }
        if let f = h.percentEncodedFragment { path += "#" + f }
        return path
    }
}
