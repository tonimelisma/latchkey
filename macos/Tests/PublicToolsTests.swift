import Foundation
import Testing

@testable import Latchkey

/// How each of the tools Claude sees reaches its operations. Their names, descriptions, annotations and input
/// schemas aren't pinned by tests (decided 2026-11-26); this suite checks how the levels shape the tool list.
@Suite struct PublicToolsTests {
    /// At read-only levels only the tools that look are left, and a capability turned off has none.
    @MainActor @Test func readOnlyLevelsKeepOnlyLooking() {
        let full = CapabilityRegistry(
            capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels)
        let looking = Set(full.tools.filter { $0.annotations?.readOnlyHint == true }.map(\.name))
        #expect(looking.contains("shell_check"))
        var levels = CapabilityRegistry.defaultLevels.mapValues { _ in AccessLevel.readOnly }
        levels[CapabilityRegistry.shell] = .off
        let registry = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: levels)
        #expect(Set(registry.tools.map(\.name)) == looking.subtracting(["shell_check"]))
    }

    @Test func notesFindListsFoldersWhenAskedForNothing() async throws {
        let store = try NotesStore(url: NotesFixture.make())
        let find = try #require(NotesCapability.readTools(store: { store }).first { $0.tool.name == "notes_find" })
        let all = await find.handler(.object([:])).content.jsonText
        #expect(all.contains("Trips: 1 notes") && all.contains("Groceries"))
        let hits = await find.handler(.object(["query": .string("lisbon")])).content.jsonText
        #expect(hits.contains("Lisbon trip") && !hits.contains("Trips: 1 notes"))
    }

    @Test func notesChangeRoutesEachAction() async throws {
        let store = try NotesStore(url: NotesFixture.make())
        let fake = FakeScripts()
        let change = try #require(NotesCapability.writeTools(store: { store }, scripts: fake).first)
        let r = await change.handler(
            .object(["action": .string("append"), "id": .string("N-IDEAS"), "text": .string("Plant tulips")]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(fake.lastArgs.last == "<div>Plant tulips</div>")
        let bad = await change.handler(.object(["action": .string("archive")]))
        #expect(bad.isError)
        #expect(bad.content.jsonText.contains("create, append, replace, edit, rename, move, delete"))
        let moved = await change.handler(
            .object(["action": .string("move"), "id": .string("N-IDEAS"), "folder": .string("Garden")]))
        #expect(!moved.isError, "\(moved.content.jsonText)")
        #expect(fake.lastArgs.last == "Garden")
    }

    @Test func filesFindListsSearchesAndDescribes() async throws {
        let f = try FilesFixture()
        let fake = FakeCommands()
        fake.output = f.path("Documents/lease.txt")
        let find = try #require(
            FilesCapability.readTools(home: f.root, commands: fake).first { $0.tool.name == "files_find" })
        let listed = await find.handler(.object(["path": .string("Documents")]))
        #expect(listed.content.jsonText.contains("lease.txt"))
        let described = await find.handler(.object(["path": .string("Documents/lease.txt")]))
        #expect(described.content.jsonText.contains("size"))
        _ = await find.handler(.object(["query": .string("pets"), "path": .string("Documents")]))
        #expect(fake.calls.first == ["/usr/bin/mdfind", "-onlyin", f.path("Documents"), "pets"])
    }

    @Test func filesChangeMovesAndTrashes() async throws {
        let f = try FilesFixture()
        let change = try #require(FilesCapability.writeTools(home: f.root).first)
        let moved = await change.handler(
            .object(["action": .string("move"), "path": .string("photo.png"), "to": .string("Archive/photo.png")]))
        #expect(!moved.isError, "\(moved.content.jsonText)")
        #expect(FileManager.default.fileExists(atPath: f.path("Archive/photo.png")))
        let edited = await change.handler(
            .object([
                "action": .string("edit"), "path": .string("Documents/lease.txt"), "find": .string("No smoking."),
                "text": .string("Smoking outside."),
            ]))
        #expect(!edited.isError, "\(edited.content.jsonText)")
    }

    @Test func shellRunTypesIntoAndStopsJobs() async throws {
        let tools = Dictionary(
            uniqueKeysWithValues: ShellCapability.tools(jobs: ShellJobs()).map { ($0.tool.name, $0) })
        let started = await tools["shell_run"]!.handler(
            .object(["command": .string("printf 'Name? '; read -r n; echo \"got $n\""), "wait": .number(1)]))
        let job = try #require(started.content.jsonText.range(of: #"job\d+"#, options: .regularExpression)).lowerBound
        let id = String(started.content.jsonText[job...].prefix { $0.isLetter || $0.isNumber })
        let typed = await tools["shell_run"]!.handler(.object(["job": .string(id), "input": .string("Sam")]))
        let checked = await tools["shell_check"]!.handler(.object(["job": .string(id), "wait": .number(5)]))
        #expect((typed.content.jsonText + checked.content.jsonText).contains("got Sam"))
        let list = await tools["shell_check"]!.handler(.object([:]))
        #expect(list.content.jsonText.contains(id))
    }

    @MainActor @Test func browserReadOpensAndActClicks() async throws {
        let b = SafariBrowser(scripts: FakeSafariTabs())
        let pages = OwnPages(cookies: { [] })
        defer { pages.closeAll() }
        let read = try #require(BrowserCapability.readTools(browser: b, own: pages).first)
        let act = try #require(BrowserCapability.writeTools(browser: b, own: pages).first)
        let opened = await read.handler(.object(["url": .string("about:blank")]))
        #expect(!opened.isError, "\(opened.content.jsonText)")
        let built = await act.handler(
            .object([
                "action": .string("script"),
                "code": .string("document.body.innerHTML = '<button onclick=\"document.title = 1\">Buy</button>'; 1"),
            ]))
        #expect(!built.isError, "\(built.content.jsonText)")
        let page = await read.handler(.object([:]))
        #expect(page.content.jsonText.contains("[e1] button: Buy"), "\(page.content.jsonText)")
        let clicked = await act.handler(.object(["action": .string("click"), "ref": .string("e1")]))
        #expect(!clicked.isError, "\(clicked.content.jsonText)")
    }

    @Test func computerActDragsFromXY() async throws {
        let poster = FakePoster()
        let env = ComputerEnvironment(
            screen: FakeScreen(), poster: poster,
            capture: { _ in PreparedImage(data: NotesFixture.pngPixel, mimeType: "image/png") }, ui: { [] },
            apps: { [] }, permissions: { (true, true) }, notify: { _ in }, openApp: { _ in }, settle: .zero)
        let act = try #require(ComputerCapability.writeTools(env: env).first)
        let r = await act.handler(
            .object([
                "action": .string("drag"), "x": .number(100), "y": .number(100), "to_x": .number(200),
                "to_y": .number(300),
            ]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(poster.events.first == .move(ScreenGeometry.point(x: 100, y: 100, on: Displays.main)))
        let look = try #require(ComputerCapability.readTools(env: env).first)
        let apps = await look.handler(.object(["show": .string("apps")]))
        #expect(!apps.isError)
    }
}
