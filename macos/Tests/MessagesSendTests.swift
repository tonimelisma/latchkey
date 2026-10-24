import Foundation
import Testing

@testable import Latchkey

@Suite struct MessagesSendTests {
    struct Setup {
        var db: URL
        var fake: FakeScripts
        var staging: URL
        var send: ToolEntry
    }

    /// `chat`: the fixture conversation Messages records the sent message in (nil: nothing recorded).
    func setup(recordIn chat: Int? = 1, error: Int = 0) throws -> Setup {
        let db = try MessagesFixture.make()
        let store = try MessagesStore(url: db, contacts: MessagesFixture.FakeContacts())
        let fake = FakeScripts()
        fake.answer = { _, _ in
            if let chat { MessagesFixture.recordOutgoing(in: db, chat: chat, text: "sent", error: error) }
            return ""
        }
        let staging = FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)")
        let tools = MessagesCapability.writeOperations(
            store: { store }, contacts: MessagesFixture.FakeContacts(), scripts: fake, staging: staging,
            confirmWait: .milliseconds(600))
        return Setup(db: db, fake: fake, staging: staging, send: try #require(tools.first))
    }

    func send(_ s: Setup, _ args: [String: JSONValue]) async -> ToolResult { await s.send.handler(.object(args)) }

    @Test func declaresItsHints() throws {
        let tool = try setup().send.tool
        #expect(tool.name == "messages_send")
        #expect(tool.annotations?.readOnlyHint == false)
        #expect(tool.annotations?.destructiveHint == false)
        #expect(tool.annotations?.openWorldHint == true, "it reaches other people")
    }

    @Test func sendsToAContactsExistingConversation() async throws {
        let s = try setup()
        let result = await send(s, ["to": .string("sarah"), "text": .string("Ten minutes late")])
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(s.fake.lastArgs == ["chat", "iMessage;-;+15551234567", "Ten minutes late"])
        #expect(result.content.jsonText.contains("Sent to Sarah Lee"))
        #expect(result.activity == "Claude sent a message to Sarah Lee")
    }

    @Test func sendsToAGroupByName() async throws {
        let s = try setup(recordIn: 2)
        let result = await send(s, ["to": .string("Dinner club"), "text": .string("Wine is on me")])
        #expect(!result.isError, "\(result.content.jsonText)")
        #expect(s.fake.lastArgs.prefix(2) == ["chat", "iMessage;+;chat123"])
    }

    @Test func sendsToANumberWrittenAnyWay() async throws {
        let s = try setup()
        _ = await send(s, ["to": .string("(555) 123-4567"), "text": .string("Hi")])
        #expect(s.fake.lastArgs.prefix(2) == ["chat", "iMessage;-;+15551234567"], "the existing conversation")
    }

    @Test func startsANewConversationWithAnAddress() async throws {
        let s = try setup(recordIn: nil)
        let result = await send(s, ["to": .string("new@example.com"), "text": .string("Hello")])
        #expect(s.fake.lastArgs.prefix(2) == ["participant", "new@example.com"])
        #expect(!result.isError, "not confirmed yet is not a failure")
        #expect(result.content.jsonText.contains("hasn't confirmed"))
    }

    @Test func asksWhenTheNameIsAmbiguous() async throws {
        let s = try setup()
        let sam = await send(s, ["to": .string("Sam"), "text": .string("Hi")])
        #expect(sam.isError)
        #expect(sam.content.jsonText.contains("Sam Ito") && sam.content.jsonText.contains("Sam Ross"))
        let ann = await send(s, ["to": .string("Ann"), "text": .string("Hi")])
        #expect(ann.isError, "one person, two numbers, no conversation yet")
        #expect(ann.content.jsonText.contains("ann@example.com"))
        let nobody = await send(s, ["to": .string("Zed"), "text": .string("Hi")])
        #expect(nobody.isError)
        #expect(s.fake.calls.isEmpty, "nothing was sent")
    }

    @Test func sendsAttachmentsFromPictures() async throws {
        let s = try setup()
        let file = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: file)
        let result = await send(s, ["to": .string("Sarah"), "attachments": .array([.string(file.path)])])
        #expect(!result.isError, "\(result.content.jsonText)")
        let sent = try #require(s.fake.lastArgs.last)
        #expect(sent.hasPrefix(s.staging.path), "copied to the Pictures folder first")
        #expect(FileManager.default.contents(atPath: sent) == Data("%PDF".utf8))
        #expect(s.fake.lastArgs[2] == "", "no text")
    }

    @Test func missingFilesAreRefusedBeforeSending() async throws {
        let s = try setup()
        let result = await send(s, ["to": .string("Sarah"), "attachments": .array([.string("/nope/missing.jpg")])])
        #expect(result.isError)
        #expect(result.content.jsonText.contains("/nope/missing.jpg"))
        #expect(s.fake.calls.isEmpty)
    }

    @Test func reportsAFailedSend() async throws {
        let s = try setup(error: 22)
        let result = await send(s, ["to": .string("Sarah"), "text": .string("Hi")])
        #expect(result.isError)
        #expect(result.content.jsonText.contains("couldn't send"))
    }

    @Test func needsSomethingToSend() async throws {
        let s = try setup()
        #expect(await send(s, ["to": .string("Sarah")]).isError)
        #expect(s.fake.calls.isEmpty)
    }

    @Test func removesOldCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appending(path: "old.jpg")
        let fresh = dir.appending(path: "fresh.jpg")
        try Data([1]).write(to: old)
        try Data([1]).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: old.path)
        MessagesCapability.removeOldCopies(in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
