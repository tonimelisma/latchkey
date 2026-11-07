import Foundation
import Testing

@testable import Latchkey

/// The README says what Latchkey does and what works when (CLAUDE.md, Toni 2026-11-07): every
/// capability Claude can be given is named in its "What Latchkey does" section, and the "What works
/// when" section is there.
@Suite struct ReadmeTests {
    static let readme: String = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "README.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    static func section(_ heading: String) -> String {
        guard let start = readme.range(of: "## \(heading)\n") else { return "" }
        let rest = readme[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @MainActor @Test func everyCapabilityIsInWhatLatchkeyDoes() {
        let does = Self.section("What Latchkey does")
        #expect(!does.isEmpty, "the README has a \"What Latchkey does\" section")
        // The README's words for each capability's title.
        let words = [
            "Notes": "Notes", "Messages": "Messages", "WhatsApp": "WhatsApp", "Files": "Files", "Shell": "Command line",
            "Browser": "Safari", "Computer Control": "screen", "Calendar": "Calendar", "Reminders": "Reminders",
            "Contacts": "Contacts", "Location & Maps": "maps",
        ]
        for c in AppModel.makeCapabilities() {
            let word = words[c.title]
            #expect(word != nil, "a README word for the new capability \(c.title)")
            if let word { #expect(does.contains(word), "\(c.title) is described in What Latchkey does") }
        }
    }

    @Test func whatWorksWhenIsThere() {
        let when = Self.section("What works when")
        #expect(when.contains("locked"))
        #expect(when.contains("unlocked"))
    }
}
