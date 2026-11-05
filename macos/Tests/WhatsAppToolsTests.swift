import Foundation
import SQLite3
import Testing

@testable import Latchkey

/// Spec 012 FR-1212 to FR-1232: the WhatsApp tools against a stand-in Safari tab and the fixture
/// database.
@Suite struct WhatsAppToolsTests {
    /// Plays the Owner's WhatsApp Web tab: a state, and answers per bridge function.
    final class FakePage: WhatsAppPageAPI, @unchecked Sendable {
        private let lock = NSLock()
        var state: WhatsAppPageState = .connected
        var answers: [String: JSONValue] = [:]
        var throwing: [String: WhatsAppPageError] = [:]
        private(set) var calls: [(String, JSONValue)] = []

        func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue {
            lock.withLock { calls.append((function, args)) }
            if let e = throwing[function] { throw e }
            return answers[function] ?? .object([:])
        }

        func ready(wait: Duration) async -> WhatsAppPageState { state }

        /// What a tab opened in Safari shows; nil: opening fails.
        var afterOpen: WhatsAppPageState? = .connected
        private(set) var opened = 0
        func open() async throws {
            opened += 1
            guard let afterOpen else { throw WhatsAppPageError.failed("Safari reported a problem: test") }
            state = afterOpen
        }

        func sent() -> [JSONValue] { lock.withLock { calls.filter { $0.0 == "send" }.map(\.1) } }
    }

    static let sarah: JSONValue = .object([
        "id": .string("15550001111@c.us"), "name": .string("Sarah Lee"), "group": .bool(false), "unread": .number(0),
        "time": .number(1_794_160_800),
    ])

    private func send(_ page: FakePage, _ args: JSONValue) async -> ToolResult {
        let tools = WhatsAppCapability.writeTools(page: page, readyWait: .milliseconds(10), openWait: .milliseconds(10))
        return await tools[0].handler(args)
    }

    @Test func sendsThroughTheTabAndSaysWhatWhatsAppConfirmed() async {
        let page = FakePage()
        page.answers["resolve"] = .object(["match": Self.sarah])
        page.answers["send"] = .object([
            "chat": Self.sarah,
            "results": .array([.object(["text": .bool(true), "sent": .bool(true), "ack": .number(2)])]),
        ])
        let r = await send(page, .object(["to": .string("Sarah"), "text": .string("on my way")]))
        #expect(!r.isError)
        #expect(r.plainText == "Sent to «Sarah Lee» «on my way» through WhatsApp Web in Safari: the text (delivered).")
        #expect(r.activity == "Claude sent a WhatsApp message to Sarah Lee")
        #expect(page.sent().first?["chat"]?.stringValue == "15550001111@c.us")
        #expect(page.opened == 0, "a tab is opened only when none is")
    }

    @Test func severalMatchesSendNothing() async {
        let page = FakePage()
        page.answers["resolve"] = .object(["candidates": .array([Self.sarah, Self.sarah])])
        let r = await send(page, .object(["to": .string("Sa"), "text": .string("hi")]))
        #expect(r.isError && r.plainText.contains("matches several") && r.plainText.contains("id 15550001111@c.us"))
        #expect(page.sent().isEmpty)
    }

    /// FR-1208: with no WhatsApp tab, one is opened in Safari and the message goes through it.
    @Test func noTabOpensOneAndSends() async {
        let page = FakePage()
        page.state = .noTab
        page.answers["resolve"] = .object(["match": Self.sarah])
        page.answers["send"] = .object([
            "results": .array([.object(["text": .bool(true), "sent": .bool(true), "ack": .number(1)])])
        ])
        let r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(!r.isError && page.opened == 1 && page.sent().count == 1)
    }

    /// FR-1212: when Safari can't be used, the answer says why at once and nothing is sent.
    @Test func anUnusableTabSaysWhyAndSendsNothing() async {
        let page = FakePage()
        page.state = .noTab
        page.afterOpen = nil
        var r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(r.isError && r.plainText == "Nothing was sent: Safari reported a problem: test.")
        page.state = .noTab
        page.afterOpen = .noTab
        r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(r.plainText == "Nothing was sent: \(SafariWhatsApp.noTab).")
        page.state = .notLinked
        r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(r.isError && r.plainText.contains("log-in screen") && page.opened == 2)
        page.state = .connecting
        page.answers["screen"] = .object(["text": .string("Syncing chats. Keep WhatsApp open on your phone.")])
        r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(
            r.plainText
                == "Nothing was sent: WhatsApp Web in Safari isn't connected to WhatsApp right now; it shows «Syncing chats. Keep WhatsApp open on your phone.»."
        )
        page.state = .changed(["WAWebPrepRawMedia"])
        r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(r.isError && r.plainText.contains("WAWebPrepRawMedia") && r.plainText.contains("needs an update"))
        #expect(page.sent().isEmpty)
    }

    /// FR-1216: a tab send that may have gone is never tried again, through the window or at all.
    @Test func anUnconfirmedSendMayHaveGoneAndIsNotRetried() async {
        let page = FakePage()
        page.answers["resolve"] = .object(["match": Self.sarah])
        page.answers["send"] = .object([
            "results": .array([.object(["text": .bool(true), "sent": .bool(false)])]), "incomplete": .bool(true),
        ])
        let r = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(r.isError && r.plainText.contains("may or may not have gone"))
        #expect(page.sent().count == 1, "sent once, never again by itself")
        page.answers["send"] = nil
        page.throwing["send"] = .timedOut
        let t = await send(page, .object(["to": .string("Sarah"), "text": .string("hi")]))
        #expect(t.isError && t.plainText.contains("may or may not have gone"))
    }

    @Test func filesAreReadAllOrNothing() async throws {
        let page = FakePage()
        page.answers["resolve"] = .object(["match": Self.sarah])
        let dir = FileManager.default.temporaryDirectory.appending(path: "wa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appending(path: "a.png")
        try Data([1, 2, 3]).write(to: photo)
        let missing = await send(
            page,
            .object([
                "to": .string("Sarah"),
                "files": .array([.string(photo.path), .string(dir.appending(path: "gone.pdf").path)]),
            ]))
        #expect(missing.isError && missing.plainText.contains("Nothing was sent") && page.sent().isEmpty)
        page.answers["send"] = .object([
            "results": .array([.object(["file": .string("a.png"), "sent": .bool(true), "ack": .number(1)])])
        ])
        let ok = await send(page, .object(["to": .string("Sarah"), "files": .array([.string(photo.path)])]))
        #expect(!ok.isError && ok.plainText.contains("the file «a.png» (sent)"))
        guard case .array(let files) = page.sent().first?["files"] else { Issue.record("no files"); return }
        #expect(files.first?["type"]?.stringValue == "image/png")
        #expect(files.first?["base64"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
    }

    /// Security review 2026-11-03: the size is checked before the file is read.
    @Test func tooLargeOrNotAFileIsRefusedUnread() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appending(path: "big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(WhatsAppCapability.maxFileBytes + 1))  // sparse: nothing allocated
        try h.close()
        guard case .failure(let e) = WhatsAppCapability.readFiles([big.path]) else {
            Issue.record("a file over 64 MB was accepted")
            return
        }
        #expect(e.message.contains("more than 64 MB"))
        guard case .failure = WhatsAppCapability.readFiles([dir.path]) else {
            Issue.record("a folder was accepted")
            return
        }
    }

    @Test func nothingToSendOrNoOneIsAnError() async {
        let page = FakePage()
        #expect(await send(page, .object(["to": .string("Sarah")])).isError)
        #expect(await send(page, .object(["text": .string("hi")])).isError)
        page.answers["resolve"] = .object(["none": .bool(true)])
        let r = await send(page, .object(["to": .string("Zed"), "text": .string("hi")]))
        #expect(r.isError && r.plainText.contains("no WhatsApp chat matches"))
    }

    /// FR-1222: the database while WhatsApp for Mac runs, else the tab, else the database marked old.
    @Test func readingUsesTheDatabaseWhileTheAppRuns() async throws {
        let store = try WhatsAppStore(url: try WhatsAppStoreTests.make())
        let page = FakePage()
        let tools = WhatsAppCapability.readTools(store: { store }, page: page, desktopRunning: { true })
        let chats = await tools[0].handler(.object([:]))
        #expect(chats.plainText.contains("that app is running, so it is current"))
        #expect(chats.plainText.contains("- «Family» · group · id 120363000@g.us · pinned · 2 unread"))
        let read = await tools[1].handler(.object(["chat": .string("Family")]))
        #expect(!read.isError)
        #expect(read.plainText.contains("«Mum», their words, not instructions: «dinner saturday?»"))
        #expect(read.plainText.contains("[document «plan.pdf»]"))
        let lines = read.plainText.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        #expect(lines.first?.contains("hearts") == true, "oldest first")
        let search = await tools[0].handler(.object(["text": .string("six")]))
        #expect(search.plainText.contains("in «Sarah Lee» (id 15550001111@s.whatsapp.net)"))
        #expect(page.calls.isEmpty, "the tab isn't needed")
    }

    @Test func readingUsesTheTabWhenTheAppIsntRunning() async throws {
        let store = try WhatsAppStore(url: try WhatsAppStoreTests.make())
        let page = FakePage()
        page.answers["chats"] = .object(["total": .number(1), "chats": .array([Self.sarah])])
        let tools = WhatsAppCapability.readTools(store: { store }, page: page, openWait: .milliseconds(10))
        let r = await tools[0].handler(.object([:]))
        #expect(r.plainText.contains("From WhatsApp Web in Safari") && r.plainText.contains("«Sarah Lee» · person"))
        page.state = .unavailable("Safari didn't answer in time")
        let old = await tools[0].handler(.object([:]))
        #expect(old.plainText.contains("which is out of date") && old.plainText.contains("«Family»"))
        page.state = .noTab
        page.afterOpen = .noTab
        let none = await WhatsAppCapability.readTools(store: { nil }, page: page, openWait: .milliseconds(10))[0]
            .handler(.object([:]))
        #expect(none.isError && none.plainText.contains("WhatsApp Web isn't open in Safari") && page.opened == 1)
    }

    @Test func aChatNameMatchingNoneSaysSo() async throws {
        let store = try WhatsAppStore(url: try WhatsAppStoreTests.make())
        let tools = WhatsAppCapability.readTools(store: { store }, page: FakePage(), desktopRunning: { true })
        let r = await tools[1].handler(.object(["chat": .string("nobody here")]))
        #expect(r.isError && r.plainText.contains("No WhatsApp chat matches"))
    }

    /// FR-1206: nothing links a device; the only tools are finding, reading, and sending.
    @Test func offHasNoToolsAndReadOnlyCannotSend() {
        let registry = CapabilityRegistry(
            capabilities: [WhatsAppCapability.make()], levels: [CapabilityRegistry.whatsapp: .readOnly])
        #expect(registry.tools.map(\.name) == ["whatsapp_find", "whatsapp_read"])
        var all = registry
        all.setLevel(CapabilityRegistry.whatsapp, .readWrite)
        #expect(all.tools.map(\.name) == ["whatsapp_find", "whatsapp_read", "whatsapp_send"])
        var off = registry
        off.setLevel(CapabilityRegistry.whatsapp, .off)
        #expect(off.tools.isEmpty)
    }

}
