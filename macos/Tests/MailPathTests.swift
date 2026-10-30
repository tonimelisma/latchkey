import Foundation
import Testing

@testable import Latchkey

/// Attachment names come from the sender: they never become part of a path (security review
/// 2026-10-29).
@Suite struct MailPathTests {
    @Test(arguments: [
        "..", ".", "../../x", "/etc/passwd", "a/../../b.txt", "evil\u{0}.txt", "", "  ", "C:\\x", ".hidden",
    ])
    func namesStayOneHarmlessComponent(_ name: String) {
        let safe = MailPaths.safeName(name, fallback: "attachment")
        #expect(!safe.isEmpty && !safe.contains("/") && !safe.contains("\u{0}") && !safe.contains(":"))
        #expect(safe != "." && safe != ".." && !safe.hasPrefix("."))
        let folder = FileManager.default.temporaryDirectory.appending(path: "paths-\(UUID().uuidString)")
        #expect(
            folder.appending(path: safe).standardizedFileURL.deletingLastPathComponent().path
                == folder.standardizedFileURL.path)
    }

    @Test func extensionsAreKeptOnlyWhenPlain() {
        #expect(MailPaths.safeExtension("lease.pdf") == "pdf")
        #expect(MailPaths.safeExtension("x.tar/../../y") == "")
        #expect(MailPaths.safeExtension("noext") == "")
        #expect(MailPaths.safeExtension("a.verylongextension") == "")
    }

    @Test func insideRefusesWhatLeadsOut() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "inside-\(UUID().uuidString)")
        let folder = base.appending(path: "folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = base.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: outside)
        try Data("ok".utf8).write(to: folder.appending(path: "plain.txt"))
        try fm.createSymbolicLink(at: folder.appending(path: "link.txt"), withDestinationURL: outside)
        #expect(MailPaths.inside(folder.appending(path: "plain.txt"), folder) != nil)
        #expect(MailPaths.inside(folder.appending(path: "link.txt"), folder) == nil)
        #expect(MailPaths.inside(folder.appending(path: "../secret.txt"), folder) == nil)
        #expect(MailPaths.inside(URL(filePath: "/etc/hosts"), folder) == nil)
        #expect(MailPaths.inside(folder, folder) == nil, "the folder itself isn't a file in it")
    }

    @Test func downloadedCopiesAreFoundByTheIndexNotTheName() throws {
        let f = try MailFixture()
        defer { f.close() }
        let s = try MailStore(root: f.root)
        let m = try s.message(1004)
        let file = try #require(s.file(for: m))
        let folder = s.attachmentsFolder(for: file, id: 1004)
        // A sender-chosen name that walks out, and a symlink planted in Mail's folder.
        let outside = f.root.appending(path: "outside.txt")
        try Data("not mail".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: folder.appending(path: "3"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "3/budget.xlsx"), withDestinationURL: outside)
        let evil = MailFile.Attachment(
            number: 9, name: "../../../outside.txt", mimeType: "text/plain", size: 1, data: nil)
        #expect(MailCapability.downloaded(evil, file, m, s) == nil)
        let budget = MailFile.Attachment(number: 2, name: "budget.xlsx", mimeType: "x", size: 1, data: nil)
        #expect(MailCapability.downloaded(budget, file, m, s) == nil, "a symlink out is refused")
        let plan = MailFile.Attachment(number: 1, name: "plan.txt", mimeType: "text/plain", size: 1, data: nil)
        #expect(MailCapability.downloaded(plan, file, m, s) != nil)
    }

    @Test func mailSavesToANameLatchkeyChose() async throws {
        let f = try MailFixture()
        defer { f.close() }
        let scripts = FakeScripts()
        scripts.answer = { script, args in
            guard script == MailScript.saveAttachment else { return "" }
            try Data("downloaded".utf8).write(to: URL(filePath: args[4]))
            return "saved"
        }
        let env = try MailTestEnv.make(f, scripts: scripts, may: true)
        let s = try MailStore(root: f.root)
        let evil = MailFile.Attachment(
            number: 9, name: "../../../../etc/x.txt", mimeType: "text/plain", size: 1, data: nil)
        let data = try await MailCapability.download(evil, try s.message(1004), env)
        #expect(data == Data("downloaded".utf8))
        let args = try #require(scripts.calls.last?.args)
        #expect(args[3] == "../../../../etc/x.txt", "the name is only matched against Mail's attachments")
        let dest = URL(filePath: args[4])
        #expect(dest.path.hasPrefix(env.downloads.path) && !dest.path.contains("..") && dest.pathExtension == "txt")
        #expect(!MailScript.saveAttachment.contains("& attName"))
    }

    @Test func forwardedCopiesStayInTheirFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fwd-\(UUID().uuidString)")
        for name in ["../../evil.txt", "/etc/passwd", "..", "a\u{0}b"] {
            let f = try MailPaths.writeCopy(Data("x".utf8), named: name, in: dir)
            #expect(
                f.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                    == dir.standardizedFileURL.path, "\(name) → \(f.path)")
        }
    }
}
