import Foundation
import Testing

@testable import Latchkey

/// Spec 001 FR-693: each report becomes one plain text file, written once, readable only by the
/// owner, and the answer names every report that is saved.
struct FeedbackFolderTests {
    func report(_ id: String, summary: String = "Create filter ignored the click") -> FeedbackReport {
        FeedbackReport(
            id: id, at: Date(timeIntervalSince1970: 1_794_864_600), client: "Claude Code", machine: "Toni's MacBook",
            summary: summary, details: "browser_act click e56: the same page came back.")
    }

    @Test func savesEachReportOnceAsItsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = FeedbackFolder(directory: dir)
        let a = report("fb_7Q2MXK4RZB3N8P5TVWYC6DHJ9F")
        let bad = report("fb_bad", summary: "")
        #expect(folder.save([a, bad]) == [a.id])

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["2026-11-16T213000Z-\(a.id).md"])
        let file = dir.appending(path: files[0])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("# Create filter ignored the click\n"))
        #expect(text.contains("Claude app: Claude Code") && text.contains("Machine: Toni's MacBook"))
        #expect(text.contains("browser_act click e56"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // Sent again (the relay sends until saved): answered as saved, not written again.
        try Data("kept".utf8).write(to: file)
        #expect(folder.save([a]) == [a.id])
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
    }
}
