import Foundation

/// Markdown-like text (as notes_read returns it) to the HTML body Notes accepts from AppleScript
/// (plan D3). Checklists become ☐ and ☑ items: scripts can't make real ones (FR-107).
enum NoteHTML {
    static func from(_ text: String) -> String {
        var html = ""
        var open: [String] = []  // the list tags currently open, outermost first
        func closeLists(to depth: Int) {
            while open.count > depth { html += "</\(open.removeLast())>" }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            let depth = (line.count - trimmed.count) / 2
            // Checklist items are plain paragraphs: Notes' Format → Checklist turns one paragraph
            // into an item, where a bulleted list item didn't change (checked live 2026-11-05).
            if let box = checklistItem(String(trimmed)) {
                closeLists(to: 0)
                html += "<div>\(escape(box))</div>"
                continue
            }
            if let (tag, item) = listItem(String(trimmed)) {
                closeLists(to: depth + 1)
                if open.count == depth + 1, open[depth] != tag { closeLists(to: depth) }
                while open.count < depth + 1 {
                    html += "<\(tag)>"
                    open.append(tag)
                }
                html += "<li>\(escape(item))</li>"
                continue
            }
            closeLists(to: 0)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                html += "<div><br></div>"
            } else if let (level, rest) = heading(line) {
                html += "<div><h\(level)>\(escape(rest))</h\(level)></div>"
            } else {
                html += "<div>\(escape(line))</div>"
            }
        }
        closeLists(to: 0)
        return html
    }

    static func title(_ title: String) -> String { "<div><h1>\(escape(title))</h1></div>" }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func heading(_ line: String) -> (Int, String)? {
        for level in 1...3 where line.hasPrefix(String(repeating: "#", count: level) + " ") {
            return (level, String(line.dropFirst(level + 1)))
        }
        return nil
    }

    private static func checklistItem(_ s: String) -> String? {
        if s.hasPrefix("- [ ] ") { return "☐ " + s.dropFirst(6) }
        if s.hasPrefix("- [x] ") || s.hasPrefix("- [X] ") { return "☑ " + s.dropFirst(6) }
        return nil
    }

    private static func listItem(_ s: String) -> (String, String)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") { return ("ul", String(s.dropFirst(2))) }
        if let dot = s.firstIndex(of: "."), dot > s.startIndex, s[..<dot].allSatisfy(\.isNumber),
            s[s.index(after: dot)...].hasPrefix(" ")
        {
            return ("ol", String(s[s.index(dot, offsetBy: 2)...]))
        }
        return nil
    }
}
