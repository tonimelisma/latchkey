import Foundation
import Testing

@testable import Latchkey

/// Files never changes Latchkey's own files (spec 003 FR-210): a write to the settings could turn
/// a capability on at the next launch, and the activity log is the Owner's record of what Claude
/// did. Everything here lives in a temporary folder; the real files are never touched.
@Suite struct OwnFilesTests {
    let f: FilesFixture
    let own: OwnFiles
    let change: ToolEntry
    let read: [ToolEntry]

    static let settings = "Library/Preferences/net.melisma.latchkey.plist"
    static let log = "Library/Application Support/Latchkey/activity.store"

    init() throws {
        f = try FilesFixture()
        let fm = FileManager.default
        for folder in [
            "Library/Application Support/Latchkey", "Library/Preferences/ByHost", "Apps/Latchkey.app/Contents",
        ] {
            try fm.createDirectory(at: f.root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in [Self.settings, Self.log, "Apps/Latchkey.app/Contents/Info.plist"] {
            try "original".write(to: f.root.appending(path: file), atomically: true, encoding: .utf8)
        }
        own = OwnFiles(
            folders: [
                f.root.appending(path: "Library/Application Support/Latchkey"),
                f.root.appending(path: "Apps/Latchkey.app"),
            ],
            settingsFolders: [
                f.root.appending(path: "Library/Preferences"), f.root.appending(path: "Library/Preferences/ByHost"),
            ],
            settingsPrefixes: ["net.melisma.latchkey"])
        change = FilesCapability.writeTools(home: f.root, own: own)[0]
        read = FilesCapability.readTools(home: f.root, commands: FakeCommands())
    }

    func refused(_ args: [String: JSONValue], _ what: Comment) async {
        let r = await change.handler(.object(args))
        #expect(r.isError, what)
        #expect(r.content.jsonText.contains("Latchkey doesn't change its own files"), what)
        #expect(r.activity == nil, what)
    }

    func text(_ path: String) -> String? { try? String(contentsOf: f.root.appending(path: path), encoding: .utf8) }

    @Test func writesAndEditsAreRefused() async {
        await refused(
            [
                "action": .string("write"), "path": .string(Self.settings), "text": .string("x"),
                "overwrite": .bool(true),
            ],
            "replacing the settings")
        await refused(
            ["action": .string("append"), "path": .string(Self.log), "text": .string("x")], "adding to the log")
        await refused(
            ["action": .string("edit"), "path": .string(Self.log), "find": .string("original"), "text": .string("x")],
            "editing the log")
        await refused(
            [
                "action": .string("write"), "path": .string("Library/Application Support/Latchkey/new.txt"),
                "text": .string("x"),
            ],
            "a new file in the data folder")
        await refused(
            [
                "action": .string("write"),
                "path": .string("Library/Preferences/ByHost/net.melisma.latchkey.ABC.plist"),
                "text": .string("x"),
            ], "per-computer settings")
        await refused(
            ["action": .string("create_folder"), "path": .string("Apps/Latchkey.app/Contents/Extra")],
            "a folder in the app")
        #expect(text(Self.settings) == "original")
        #expect(text(Self.log) == "original")
        #expect(text("Library/Application Support/Latchkey/new.txt") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.path("Apps/Latchkey.app/Contents/Extra")))
    }

    @Test func movesCopiesAndTrashAreRefused() async {
        await refused(["action": .string("trash"), "path": .string(Self.log)], "trashing the log")
        await refused(["action": .string("trash"), "path": .string("Apps/Latchkey.app")], "trashing the app")
        await refused(
            ["action": .string("move"), "path": .string(Self.settings), "to": .string("Documents/s.plist")],
            "moving the settings away")
        await refused(
            ["action": .string("move"), "path": .string("Documents/lease.txt"), "to": .string(Self.settings + "2")],
            "moving a file in under a settings name")
        await refused(
            [
                "action": .string("move"), "path": .string("Documents/lease.txt"),
                "to": .string("Library/Application Support/Latchkey"),
            ], "moving a file into the data folder")
        await refused(
            [
                "action": .string("copy"), "path": .string("Documents/lease.txt"),
                "to": .string("Apps/Latchkey.app/Contents/lease.txt"),
            ], "copying into the app")
        // A folder that holds them can't be moved or trashed either: they would go along.
        await refused(["action": .string("trash"), "path": .string("Library")], "trashing the Library")
        await refused(
            ["action": .string("move"), "path": .string("Library/Preferences"), "to": .string("Prefs")],
            "moving the settings folder")
        #expect(text(Self.settings) == "original")
        #expect(text(Self.log) == "original")
        #expect(text("Apps/Latchkey.app/Contents/Info.plist") == "original")
        #expect(text("Documents/lease.txt") != nil, "nothing moved")
    }

    /// Another spelling of the same place is the same place: letter case (the Mac's disk ignores
    /// it), `..`, and links.
    @Test func otherSpellingsOfThePathAreRefused() async throws {
        await refused(
            [
                "action": .string("write"), "path": .string("library/preferences/NET.MELISMA.LATCHKEY.PLIST"),
                "text": .string("x"), "overwrite": .bool(true),
            ], "other letter case")
        await refused(
            [
                "action": .string("write"),
                "path": .string("Documents/../Library/Application Support/Latchkey/x.txt"), "text": .string("x"),
            ], "through ..")
        try FileManager.default.createSymbolicLink(
            at: f.root.appending(path: "shortcut"),
            withDestinationURL: f.root.appending(path: "Library/Application Support/Latchkey"))
        await refused(
            ["action": .string("write"), "path": .string("shortcut/x.txt"), "text": .string("x")], "through a link")
        await refused(
            ["action": .string("append"), "path": .string("shortcut/activity.store"), "text": .string("x")],
            "through a link, to an existing file")
        // A link to a settings file that doesn't exist yet.
        try FileManager.default.createSymbolicLink(
            atPath: f.path("dangling"),
            withDestinationPath: f.path("Library/Preferences/net.melisma.latchkey.new.plist"))
        await refused(
            ["action": .string("write"), "path": .string("dangling"), "text": .string("x"), "overwrite": .bool(true)],
            "through a link to a file that isn't there yet")
        #expect(text(Self.log) == "original")
        #expect(text("Library/Application Support/Latchkey/x.txt") == nil)
        #expect(text("Library/Preferences/net.melisma.latchkey.new.plist") == nil)
    }

    @Test func readingThemAndChangingOtherFilesStillWorks() async {
        let readTool = read.first { $0.tool.name == "files_read" }!
        let r = await readTool.handler(.object(["path": .string(Self.log)]))
        #expect(!r.isError)
        #expect(r.content.jsonText.contains("original"))
        // Other apps' settings and other files in the same folders are not Latchkey's.
        let other = await change.handler(
            .object([
                "action": .string("write"), "path": .string("Library/Preferences/com.example.app.plist"),
                "text": .string("x"),
            ]))
        #expect(!other.isError, "\(other.content.jsonText)")
        let copy = await change.handler(
            .object([
                "action": .string("copy"), "path": .string(Self.log), "to": .string("Documents/log-copy.store"),
            ]))
        #expect(!copy.isError, "copying one of them out is reading: \(copy.content.jsonText)")
        #expect(text("Documents/log-copy.store") == "original")
    }

    /// The real list: the data folder, the settings, and the app that is running.
    @Test func theAppProtectsItsRealFiles() {
        let own = OwnFiles.standard
        let library = URL.libraryDirectory
        #expect(own.holds(library.appending(path: "Application Support/Latchkey/activity.store")))
        #expect(own.holds(library.appending(path: "Preferences/net.melisma.latchkey.plist")))
        #expect(own.holds(library.appending(path: "Preferences/ByHost/net.melisma.latchkey.0000.plist")))
        #expect(own.holds(Bundle.main.bundleURL.appending(path: "Contents/Info.plist")))
        #expect(own.holds(Bundle.main.bundleURL))
        #expect(own.isAbove(library))
        #expect(!own.holds(library.appending(path: "Preferences/com.apple.finder.plist")))
        #expect(!own.holds(URL.documentsDirectory.appending(path: "notes.txt")))
        #expect(!own.isAbove(URL.documentsDirectory))
    }
}
