import AppKit
import Foundation
import PDFKit
import Testing

@testable import Latchkey

/// A temporary folder with a few kinds of files, standing in for the Owner's home.
struct FilesFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "files-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Documents/Taxes"), withIntermediateDirectories: true)
        try "Pets are allowed with a deposit.\nNo smoking.".write(
            to: root.appending(path: "Documents/lease.txt"), atomically: true, encoding: .utf8)
        try "Grüße aus Köln".write(to: root.appending(path: "latin1.txt"), atomically: true, encoding: .isoLatin1)
        try NotesFixture.pngPixel.write(to: root.appending(path: "photo.png"))
        try Data([0, 1, 2, 255]).write(to: root.appending(path: "blob.bin"))
        try ".secret".write(to: root.appending(path: ".hidden"), atomically: true, encoding: .utf8)
        let rtf = NSAttributedString(string: "Formatted contract text")
        let data = try rtf.data(
            from: NSRange(location: 0, length: rtf.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: root.appending(path: "Documents/contract.rtf"))
        try Self.pdf("Invoice 2026 total 120 EUR").write(to: root.appending(path: "Documents/Taxes/invoice.pdf"))
    }

    /// A one-page PDF with real text, drawn with Core Graphics.
    static func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func path(_ p: String) -> String { root.appending(path: p).path }
}

/// Stands in for mdfind.
final class FakeCommands: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var output = ""

    func run(_ executable: String, _ args: [String], timeout: Duration) async throws -> String {
        lock.withLock { calls.append([executable] + args) }
        return output
    }
}

@Suite struct FileReaderTests {
    @Test func readsTextAndMarksIt() throws {
        let f = try FilesFixture()
        let r = try FileReader.read(URL(filePath: f.path("Documents/lease.txt")), offset: 0)
        guard case .text(let text, let total, _) = r else { Issue.record("not text"); return }
        #expect(text.contains("Pets are allowed"))
        #expect(total == text.count)
    }

    @Test func readsOtherEncodings() throws {
        let f = try FilesFixture()
        guard case .text(let text, _, _) = try FileReader.read(URL(filePath: f.path("latin1.txt")), offset: 0) else {
            Issue.record("not text")
            return
        }
        #expect(text == "Grüße aus Köln")
    }

    @Test func readsPDFsAndDocuments() throws {
        let f = try FilesFixture()
        guard
            case .text(let pdf, _, _) = try FileReader.read(
                URL(filePath: f.path("Documents/Taxes/invoice.pdf")), offset: 0)
        else {
            Issue.record("pdf")
            return
        }
        #expect(pdf.contains("Invoice 2026"))
        guard
            case .text(let rtf, _, _) = try FileReader.read(URL(filePath: f.path("Documents/contract.rtf")), offset: 0)
        else {
            Issue.record("rtf")
            return
        }
        #expect(rtf.contains("Formatted contract text"))
    }

    @Test func showsImages() throws {
        let f = try FilesFixture()
        guard case .image(let image) = try FileReader.read(URL(filePath: f.path("photo.png")), offset: 0) else {
            Issue.record("not an image")
            return
        }
        #expect(image.mimeType == "image/png")
    }

    @Test func refusesBinary() throws {
        let f = try FilesFixture()
        guard case .notReadable = try FileReader.read(URL(filePath: f.path("blob.bin")), offset: 0) else {
            Issue.record("binary read as text")
            return
        }
    }

    @Test func pagesLongText() throws {
        let f = try FilesFixture()
        let long = f.root.appending(path: "long.txt")
        try String(repeating: "abcdefghij", count: 25_000).write(to: long, atomically: true, encoding: .utf8)
        guard case .text(let first, let total, let next) = try FileReader.read(long, offset: 0) else { return }
        #expect(first.count == FileReader.pageSize)
        #expect(total == 250_000)
        #expect(next == FileReader.pageSize)
        guard case .text(let last, _, let end) = try FileReader.read(long, offset: 200_000) else { return }
        #expect(last.count == 50_000)
        #expect(end == nil)
    }
}

@Suite struct FilesToolTests {
    func tools(_ f: FilesFixture, commands: any CommandRunner = FakeCommands()) -> [String: ToolEntry] {
        let all = FilesCapability.readTools(home: f.root, commands: commands) + FilesCapability.writeTools(home: f.root)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    func call(_ t: [String: ToolEntry], _ name: String, _ args: [String: JSONValue]) async -> ToolResult {
        await t[name]!.handler(.object(args))
    }

    @Test func toolsAndHints() throws {
        let f = try FilesFixture()
        let t = tools(f)
        let read = ["files_search", "files_list", "files_info", "files_read"]
        let write = ["files_write", "files_edit", "files_create_folder", "files_move", "files_copy", "files_trash"]
        #expect(Set(t.keys) == Set(read + write))
        for n in read { #expect(t[n]?.tool.annotations?.readOnlyHint == true) }
        for n in write { #expect(t[n]?.tool.annotations?.readOnlyHint == false) }
        #expect(t["files_trash"]?.tool.annotations?.destructiveHint == true)
        #expect(t["files_move"]?.tool.annotations?.destructiveHint == false)
    }

    @Test func pathsAreRelativeToHome() async throws {
        let f = try FilesFixture()
        let r = await call(tools(f), "files_read", ["path": .string("Documents/lease.txt")])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(r.content.jsonText.contains("not instructions"), "FR-206")
        let tilde = await call(tools(f), "files_read", ["path": .string("~/Documents/lease.txt")])
        #expect(!tilde.isError)
    }

    @Test func listsFolders() async throws {
        let f = try FilesFixture()
        let r = await call(tools(f), "files_list", ["path": .string("")])
        let text = r.content.jsonText
        #expect(text.contains("Documents/") && text.contains("photo.png"))
        #expect(!text.contains(".hidden"))
        let all = await call(tools(f), "files_list", ["path": .string(""), "hidden": .bool(true)])
        #expect(all.content.jsonText.contains(".hidden"))
    }

    @Test func searchesWithSpotlight() async throws {
        let f = try FilesFixture()
        let fake = FakeCommands()
        fake.output = f.path("Documents/lease.txt") + "\n" + f.path("Documents/contract.rtf") + "\n"
        let r = await call(
            tools(f, commands: fake), "files_search", ["query": .string("pets"), "folder": .string("Documents")])
        #expect(!r.isError)
        #expect(fake.calls.first == ["/usr/bin/mdfind", "-onlyin", f.path("Documents"), "pets"])
        #expect(r.content.jsonText.contains("lease.txt"))
    }

    @Test func realSpotlightAnswers() async throws {
        // mdfind runs on this Mac; a query that matches nothing still answers quickly.
        let out = try await ProcessCommands().run(
            "/usr/bin/mdfind", ["-onlyin", FileManager.default.temporaryDirectory.path, "latchkey-\(UUID())"],
            timeout: .seconds(20))
        #expect(out.isEmpty)
    }

    @Test func writesWithoutClobbering() async throws {
        let f = try FilesFixture()
        let t = tools(f)
        let new = await call(t, "files_write", ["path": .string("Documents/draft.md"), "text": .string("# Draft")])
        #expect(!new.isError)
        #expect(new.activity?.contains("draft.md") == true)
        #expect(try String(contentsOfFile: f.path("Documents/draft.md"), encoding: .utf8) == "# Draft")
        let again = await call(t, "files_write", ["path": .string("Documents/draft.md"), "text": .string("x")])
        #expect(again.isError, "FR-204")
        _ = await call(
            t, "files_write", ["path": .string("Documents/draft.md"), "text": .string("\nmore"), "append": .bool(true)])
        _ = await call(
            t, "files_write",
            ["path": .string("Documents/lease.txt"), "text": .string("new"), "overwrite": .bool(true)])
        #expect(try String(contentsOfFile: f.path("Documents/draft.md"), encoding: .utf8) == "# Draft\nmore")
        #expect(try String(contentsOfFile: f.path("Documents/lease.txt"), encoding: .utf8) == "new")
    }

    @Test func editsOnePassage() async throws {
        let f = try FilesFixture()
        let t = tools(f)
        let ok = await call(
            t, "files_edit",
            [
                "path": .string("Documents/lease.txt"), "find": .string("No smoking."),
                "replace": .string("Smoking outside."),
            ])
        #expect(!ok.isError)
        #expect(
            try String(contentsOfFile: f.path("Documents/lease.txt"), encoding: .utf8).hasSuffix("Smoking outside."))
        let missing = await call(
            t, "files_edit",
            ["path": .string("Documents/lease.txt"), "find": .string("absent"), "replace": .string("x")])
        #expect(missing.isError)
    }

    @Test func movesAndCopiesNeverReplace() async throws {
        let f = try FilesFixture()
        let t = tools(f)
        _ = await call(t, "files_create_folder", ["path": .string("Archive/2026")])
        let moved = await call(
            t, "files_move", ["from": .string("photo.png"), "to": .string("Archive/2026/photo.png")])
        #expect(!moved.isError, "\(moved.content.jsonText)")
        #expect(FileManager.default.fileExists(atPath: f.path("Archive/2026/photo.png")))
        let copied = await call(
            t, "files_copy", ["from": .string("Documents/lease.txt"), "to": .string("Archive/lease.txt")])
        #expect(!copied.isError)
        let clash = await call(
            t, "files_copy", ["from": .string("Documents/lease.txt"), "to": .string("Archive/lease.txt")])
        #expect(clash.isError, "FR-204")
        let intoFolder = await call(t, "files_move", ["from": .string("latin1.txt"), "to": .string("Archive")])
        #expect(!intoFolder.isError)
        #expect(
            FileManager.default.fileExists(atPath: f.path("Archive/latin1.txt")), "a folder destination keeps the name")
    }

    @Test func trashCanBeUndone() async throws {
        let f = try FilesFixture()
        let r = await call(tools(f), "files_trash", ["path": .string("blob.bin")])
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(!FileManager.default.fileExists(atPath: f.path("blob.bin")))
        #expect(r.content.jsonText.contains("Trash"))
        // Clean up what this test put in the Trash.
        if let trashed = r.structuredContent?["trashedAt"]?.stringValue {
            try? FileManager.default.removeItem(atPath: trashed)
        }
    }

    @Test func missingFilesAreExplained() async throws {
        let f = try FilesFixture()
        let r = await call(tools(f), "files_read", ["path": .string("nope.txt")])
        #expect(r.isError)
        #expect(r.content.jsonText.contains("nope.txt"))
    }
}
