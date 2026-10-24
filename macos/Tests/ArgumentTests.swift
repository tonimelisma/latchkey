import Foundation
import Testing

@testable import Latchkey

/// Numbers in tool arguments arrive as JSON doubles from the relay. Converting NaN, infinity, or a
/// value past Int's range with Int(_:) crashes the app (security scan, 2026-10-24); every tool
/// turns them away with a clear error instead.
@Suite struct ArgumentNumberTests {
    static let unusable: [JSONValue] = [.number(1e19), .number(-1e19), .number(.nan), .number(.infinity)]

    @Test func wholeNumbersAreCheckedNotTrapped() throws {
        let args = JSONValue.object([
            "five": .number(5), "two": .number(2.0), "text": .string("7"), "huge": .number(1e19), "nan": .number(.nan),
            "inf": .number(-.infinity), "half": .number(2.5), "neg": .number(-1), "word": .string("many"),
        ])
        #expect(try args.integer("five") == 5)
        #expect(try args.integer("two") == 2)
        #expect(try args.integer("text") == 7)
        #expect(try args.integer("missing") == nil)
        #expect(try JSONValue.object(["n": .null]).integer("n") == nil)
        for key in ["huge", "nan", "inf", "half", "word"] {
            #expect(throws: ArgumentError.self, "\(key)") { try args.integer(key) }
        }
        #expect(throws: ArgumentError.self) { try args.integer("neg", in: 0...Int.max) }
        #expect(try args.integer("neg") == -1)
        let e = try #require(throws: ArgumentError.self) { try args.integer("huge", in: 0...Int.max) }
        #expect(e.message.contains("huge"))
    }

    @Test func fractionsAreCheckedToo() throws {
        let args = JSONValue.object(["x": .number(1.5), "nan": .number(.nan), "big": .number(1e300)])
        #expect(try args.number("x", in: 0...10) == 1.5)
        #expect(throws: ArgumentError.self) { try args.number("nan", in: 0...10) }
        #expect(throws: ArgumentError.self) { try args.number("big", in: 0...10) }
        #expect(try args.number("missing", in: 0...10) == nil)
    }

    @Test(arguments: unusable) func filesToolsRefuseUnusableNumbers(_ bad: JSONValue) async throws {
        let f = try FilesFixture()
        let all = FilesCapability.readOperations(home: f.root, commands: FakeCommands())
        let t = Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
        let read = await t["files_read"]!.handler(.object(["path": .string("Documents/lease.txt"), "offset": bad]))
        #expect(read.isError)
        #expect(read.content.jsonText.contains("offset"))
        let search = await t["files_search"]!.handler(.object(["query": .string("x"), "limit": bad]))
        #expect(search.isError)
        #expect(search.content.jsonText.contains("limit"))
    }

    @Test(arguments: unusable) func browserToolsRefuseUnusableNumbers(_ bad: JSONValue) async {
        let b = SafariBrowser(scripts: FakeSafari())
        let t = Dictionary(
            uniqueKeysWithValues: BrowserCapability.readOperations(browser: b).map { ($0.tool.name, $0) })
        _ = await t["browser_open"]!.handler(.object(["url": .string("https://shop.example.com/")]))
        let read = await t["browser_read"]!.handler(.object(["offset": bad]))
        #expect(read.isError)
        #expect(read.content.jsonText.contains("offset"))
        let tabs = await t["browser_tabs"]!.handler(.object(["select": bad]))
        #expect(tabs.isError)
        #expect(tabs.content.jsonText.contains("select"))
    }

    @Test(arguments: unusable) func notesToolsRefuseUnusableNumbers(_ bad: JSONValue) async throws {
        let s = try NotesStore(url: NotesFixture.make())
        let t = Dictionary(
            uniqueKeysWithValues: NotesCapability.readOperations(store: { s }).map { ($0.tool.name, $0) })
        let search = await t["notes_search"]!.handler(.object(["query": .string(""), "limit": bad]))
        #expect(search.isError)
        #expect(search.content.jsonText.contains("limit"))
        let found = await t["notes_search"]!.handler(.object(["query": .string("")]))
        let id = try #require(
            found.structuredContent?["notes"].flatMap { if case .array(let a) = $0 { a.first } else { nil } }?["id"]?
                .stringValue)
        let read = await t["notes_read"]!.handler(.object(["id": .string(id), "offset": bad]))
        #expect(read.isError)
        #expect(read.content.jsonText.contains("offset"))
    }

    @Test(arguments: unusable) func messagesToolsRefuseUnusableNumbers(_ bad: JSONValue) async throws {
        let s = try MessagesStore(url: MessagesFixture.make(), contacts: MessagesFixture.FakeContacts())
        let t = Dictionary(
            uniqueKeysWithValues: MessagesCapability.readOperations(store: { s }).map { ($0.tool.name, $0) })
        let r = await t["messages_conversations"]!.handler(.object(["limit": bad]))
        #expect(r.isError)
        #expect(r.content.jsonText.contains("limit"))
    }

    /// A long wait is cut to 30 seconds, so only NaN, infinity, and negative waits are refused.
    @Test(arguments: [JSONValue.number(-1e19), .number(.nan), .number(.infinity), .number(-1)])
    func shellRefusesUnusableNumbers(_ bad: JSONValue) async {
        let run = ShellCapability.operations(jobs: ShellJobs()).first { $0.tool.name == "shell_run" }!
        let r = await run.handler(.object(["command": .string("true"), "wait": bad]))
        #expect(r.isError)
        #expect(r.content.jsonText.contains("wait"))
    }

    @Test(arguments: unusable) func computerToolsRefuseUnusableNumbers(_ bad: JSONValue) async {
        let e = ComputerToolTests().env(FakeScreen(), FakePoster())
        let t = ComputerToolTests().tools(e)
        let shot = await t["computer_screenshot"]!.handler(.object(["display": bad]))
        #expect(shot.isError)
        #expect(shot.content.jsonText.contains("display"))
        for (key, args) in [
            ("x", ["x": bad, "y": .number(5)]), ("count", ["x": .number(5), "y": .number(5), "count": bad]),
            ("display", ["x": .number(5), "y": .number(5), "display": bad]),
        ] {
            let click = await t["computer_click"]!.handler(.object(args))
            #expect(click.isError, "\(key)")
            #expect(click.content.jsonText.contains(key))
        }
        let scroll = await t["computer_scroll"]!.handler(
            .object(["x": .number(5), "y": .number(5), "direction": .string("down"), "amount": bad]))
        #expect(scroll.isError)
        #expect(scroll.content.jsonText.contains("amount"))
    }
}
