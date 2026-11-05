import Foundation
import Testing

@testable import Latchkey

/// The 32 tools Claude sees (15 consolidated 2026-10-23, 8 added by spec 007, 5 by spec 008, 4 by spec 012) and how each reaches its operations.
@Suite struct PublicToolsTests {
    static let read = [
        "notes_find", "notes_read", "messages_find", "messages_read", "files_find", "files_read", "shell_check",
        "browser_read", "computer_look", "calendar_find", "reminders_find", "contacts_find", "location_read",
        "maps_find", "mail_find", "mail_read", "whatsapp_find", "whatsapp_read",
    ]
    static let write = [
        "notes_change", "messages_send", "files_change", "shell_run", "browser_act", "computer_act",
        "calendar_change", "reminders_change", "contacts_change", "mail_change", "mail_send", "mail_queue",
        "whatsapp_send", "whatsapp_change",
    ]

    @MainActor @Test func thirtyTwoToolsAtFullLevel() {
        let registry = CapabilityRegistry(
            capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels)
        let names = registry.tools.map(\.name)
        #expect(names.count == 32)
        #expect(Set(names) == Set(Self.read + Self.write))
        for t in registry.tools {
            #expect(t.annotations?.readOnlyHint == Self.read.contains(t.name), "\(t.name)")
            #expect(t.name.count <= 64)
        }
    }

    @MainActor @Test func readOnlyLevelsKeepOnlyLooking() {
        var levels = CapabilityRegistry.defaultLevels.mapValues { _ in AccessLevel.readOnly }
        levels[CapabilityRegistry.shell] = .off
        let registry = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: levels)
        #expect(Set(registry.tools.map(\.name)) == Set(Self.read).subtracting(["shell_check"]))
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
        #expect(bad.content.jsonText.contains("create, append, replace, edit, rename, check, uncheck, move, delete"))
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
        let typed = await tools["shell_run"]!.handler(.object(["job": .string(id), "input": .string("Toni")]))
        let checked = await tools["shell_check"]!.handler(.object(["job": .string(id), "wait": .number(5)]))
        #expect((typed.content.jsonText + checked.content.jsonText).contains("got Toni"))
        let list = await tools["shell_check"]!.handler(.object([:]))
        #expect(list.content.jsonText.contains(id))
    }

    @Test func browserReadOpensAndActClicks() async throws {
        let fake = FakeSafari()
        let b = SafariBrowser(scripts: fake)
        let read = try #require(BrowserCapability.readTools(browser: b).first)
        let act = try #require(BrowserCapability.writeTools(browser: b).first)
        let opened = await read.handler(.object(["url": .string("shop.example.com")]))
        #expect(opened.content.jsonText.contains("[e1] link: Orders"))
        let clicked = await act.handler(.object(["action": .string("click"), "ref": .string("e1")]))
        #expect(!clicked.isError)
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
