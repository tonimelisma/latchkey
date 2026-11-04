import Foundation

/// One look at an app's window (spec 006 FR-512): every element once, in the order the window
/// holds them, with references that stay the same for continued and narrowed looks at it.
struct AppListing: Sendable {
    var items: [AppElement]
    /// The walk stopped before the end of the window.
    var cut: Bool = false
    var taken = Date()

    /// Shown per answer; `after` continues.
    static let pageSize = 300

    func element(_ ref: String) -> AppElement? { items.first { $0.ref == ref } }

    /// Only the window and its title bar's buttons: the app hasn't built its tree yet.
    var onlyTitleBar: Bool { items.count <= 5 && items.allSatisfy { ["AXWindow", "AXButton"].contains($0.role) } }

    struct Page {
        var shown: [AppElement]
        /// The last shown one's reference, when more follow.
        var more: String?
    }

    /// What one answer shows: inside `within`, matching `match`, after `after`, repeats left out.
    func page(after: String? = nil, within: String? = nil, match: String? = nil, size: Int = pageSize) -> Page {
        let byRef = Dictionary(items.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        func inside(_ e: AppElement, _ root: String) -> Bool {
            var parent = e.parent
            var steps = 0
            while let p = parent, steps < 200 {
                if p == root { return true }
                parent = byRef[p]?.parent
                steps += 1
            }
            return false
        }
        var list = Self.withoutRepeats(items)
        if let within { list = list.filter { inside($0, within) } }
        if let match, !match.isEmpty {
            list = list.filter {
                $0.label.localizedCaseInsensitiveContains(match)
                    || ($0.value ?? "").localizedCaseInsensitiveContains(match)
                    || $0.role.localizedCaseInsensitiveContains(match)
            }
        }
        if let after, let i = items.firstIndex(where: { $0.ref == after }) {
            let later = Set(items[(i + 1)...].map(\.ref))
            list = list.filter { later.contains($0.ref) }
        }
        let shown = Array(list.prefix(size))
        return Page(shown: shown, more: list.count > size ? shown.last?.ref : nil)
    }

    /// A text that only repeats what is next to it: the label of the control after it, the
    /// value or label of the element it is in, or the text just before it (web pages give each
    /// label two or three times, bug report 2026-11-03).
    static func withoutRepeats(_ items: [AppElement]) -> [AppElement] {
        let byRef = Dictionary(items.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        func text(_ e: AppElement) -> String {
            (e.value.flatMap { $0.isEmpty ? nil : $0 } ?? e.label).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [AppElement] = []
        for (i, e) in items.enumerated() {
            guard e.role == "AXStaticText" else {
                out.append(e)
                continue
            }
            let t = text(e)
            if t.isEmpty { continue }
            if let previous = out.last, previous.role == "AXStaticText", text(previous) == t { continue }
            if let p = e.parent.flatMap({ byRef[$0] }), p.role != "AXStaticText",
                p.label.trimmingCharacters(in: .whitespaces) == t
                    || (p.value ?? "").trimmingCharacters(in: .whitespaces) == t
            {
                continue
            }
            let later = items[(i + 1)...]
            if let next = later.first(where: { $0.role != "AXStaticText" || (text($0) != t && !text($0).isEmpty) }),
                next.role != "AXStaticText", next.label.trimmingCharacters(in: .whitespaces) == t
            {
                continue
            }
            out.append(e)
        }
        return out
    }
}
