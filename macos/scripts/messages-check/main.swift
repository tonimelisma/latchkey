// Runs Latchkey's real Messages window code (LiveMessagesUI) against the real Messages, in a
// conversation of the Mac's owner with himself only, and checks each step in Messages'
// database. Built and run by messages-check.sh, from a terminal that has Accessibility.
//   messages-check run <own address> <own number>: a group of the two (named), a tapback given and
//     taken back, an inline reply, an edit, an unsend, a deleted message, then the sweep.
//   messages-check sweep <tag>: deletes every message with the tag (in Messages' window), and every
//     group of only the owner's own addresses that has one; exits 1 naming whatever stayed.
// MESSAGES_CHECK_DB: Messages' database, or a copy kept fresh by a program that has Full Disk
// Access (default ~/Library/Messages/chat.db).
import AppKit
import Foundation

/// Names as Messages' window shows them for the owner's own address and number (the window is
/// checked against them): MESSAGES_CHECK_NAME, e.g. the owner's name in Contacts.
struct OwnName: ContactsLookup {
    var own: Set<String>
    var name = ProcessInfo.processInfo.environment["MESSAGES_CHECK_NAME"]
    func name(for handle: String) -> String? {
        own.contains { h in
            h == handle || (h.filter(\.isNumber).count >= 7 && h.filter(\.isNumber) == handle.filter(\.isNumber))
        } ? name : nil
    }
    func people(matching name: String) -> [ContactPerson] { [] }
}

struct CheckFailure: Error { var message: String }

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
let dbURL = URL(
    filePath: env["MESSAGES_CHECK_DB"] ?? URL.homeDirectory.appending(path: "Library/Messages/chat.db").path)
let ui = LiveMessagesUI()

nonisolated(unsafe) var ownHandles: Set<String> = []
nonisolated func store() throws -> MessagesStore { try MessagesStore(url: dbURL, contacts: OwnName(own: ownHandles)) }
/// Opened afresh at each look: a copy kept fresh by another program is replaced, not changed.
nonisolated var s: MessagesStore { get throws { try store() } }

func step(_ name: String) { print("· \(name)") }

/// Looks every 250 ms for up to `seconds`.
func until<T>(_ what: String, seconds: Double = 15, _ look: () throws -> T?) async throws -> T {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let hit = try look() { return hit }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw CheckFailure(message: "Messages' database didn't show \(what) within \(Int(seconds)) s")
}

func target(_ s: MessagesStore, _ id: String) throws -> BalloonTarget {
    guard let m = try s.locate(id) else { throw CheckFailure(message: "message \(id) isn't in the database") }
    guard let who = try s.identity(of: m.conversationID) else { throw CheckFailure(message: "no conversation") }
    return BalloonTarget(
        message: id, text: m.text, attachmentNames: m.attachmentNames, fromMe: m.fromMe, laterSame: m.laterSame,
        conversation: who)
}

/// Every message (not tapback) with the tag still in a conversation: (message, conversation).
func tagged(_ s: MessagesStore, _ tag: String) throws -> [MessagesStore.Message] {
    try s.search(text: tag, person: nil, since: nil, until: nil, limit: 200)
}

func sweep(_ tag: String, own: Set<String>) async -> Bool {
    do {

        for _ in 0..<3 {
            let left = try tagged(s, tag)
            if left.isEmpty { break }
            var doneGroups = Set<String>()
            for m in left {
                if doneGroups.contains(m.conversationID) { continue }
                let located = try s.locate(m.id)
                let members = Set(try s.conversations(query: nil, limit: 500).first { $0.id == m.conversationID }?
                    .participants.map(\.handle) ?? [])
                // Only the owner's own conversations, whatever the text says.
                guard !members.isEmpty, members.isSubset(of: own) else { continue }
                if located?.isGroup == true {
                    step("deleting test group \(m.conversationID)")
                    guard let who = try s.identity(of: m.conversationID) else { continue }
                    try await ui.deleteConversation(who, showing: try s.latestMessage(in: m.conversationID) ?? m.id)
                    doneGroups.insert(m.conversationID)
                    _ = try? await until("the group gone", seconds: 10) {
                        try s.conversationIsEmpty(m.conversationID) ? true : nil
                    }
                } else {
                    step("deleting message \(m.id) «\(m.text.prefix(50))»")
                    try await ui.act(.delete, on: try target(s, m.id))
                    _ = try? await until("message \(m.id) deleted", seconds: 10) { try s.isDeleted(m.id) ? true : nil }
                }
            }
        }
        let left = try tagged(s, tag)
        if left.isEmpty {
            print("sweep: nothing with «\(tag)» is left in any conversation")
            return true
        }
        print("SWEEP FAILED, still there:")
        for m in left { print("  \(m.id) in \(m.conversationID): «\(m.text)»") }
        return false
    } catch {
        print("SWEEP FAILED: \(error)")
        return false
    }
}

func run(own address: String, number: String, tag: String) async throws {
    if let why = ui.unavailable() { throw CheckFailure(message: why) }

    // A group of the owner's own address and number, named: nobody else gets anything.
    step("new group with \(address) and \(number)")
    var start = try s.lastRow()
    try await ui.startGroup([address, number], text: "\(tag) group (please ignore)")
    let group = try await until("the new group") { try s.groupRecorded(with: [address, number], after: start) }
    let first = try await until("the first message") { try s.latestMessage(in: group) }
    step("naming it")
    guard let who = try s.identity(of: group) else { throw CheckFailure(message: "no group") }
    try await ui.nameGroup(who, showing: first, name: "\(tag) group")
    _ = try await until("the name") { try s.groupName(group) == "\(tag) group" ? true : nil }

    step("tapback like")
    start = try s.lastRow()
    try await ui.act(.tapback(.like), on: try target(s, first))
    _ = try await until("the like") { try s.reactionRecorded(on: first, type: 2001, after: start) ? true : nil }
    step("tapback like taken back")
    start = try s.lastRow()
    try await ui.act(.tapback(.like), on: try target(s, first))
    _ = try await until("the like taken back") {
        try s.reactionRecorded(on: first, type: 3001, after: start) ? true : nil
    }

    step("inline reply")
    start = try s.lastRow()
    try await ui.act(.reply("\(tag) reply (please ignore)"), on: try target(s, first))
    _ = try await until("the reply") { try s.outgoingRecorded(after: start, conversation: group, replyingTo: first) }

    step("edit")
    let edited = "\(tag) group, edited (please ignore)"
    try await ui.act(.edit(edited), on: try target(s, first))
    _ = try await until("the edit") { try s.editRecorded(first, text: edited) ? true : nil }

    step("unsend")
    start = try s.lastRow()
    try await ui.startGroup([address, number], text: "\(tag) to unsend (please ignore)")
    let second = try await until("the second message") {
        try s.outgoingRecorded(after: start, conversation: group, replyingTo: nil)?.guid
    }
    try await ui.act(.unsend, on: try target(s, second))
    _ = try await until("the unsend") { try s.isUnsent(second) ? true : nil }

    step("delete one message")
    start = try s.lastRow()
    try await ui.startGroup([address, number], text: "\(tag) to delete (please ignore)")
    let third = try await until("the third message") {
        try s.outgoingRecorded(after: start, conversation: group, replyingTo: nil)?.guid
    }
    try await ui.act(.delete, on: try target(s, third))
    _ = try await until("the deletion") { try s.isDeleted(third) ? true : nil }
    print("all steps passed")
}

guard args.count >= 3 else {
    print("usage: messages-check run <own address> <own number> | sweep <tag> <own address> <own number>")
    exit(2)
}
ownHandles = Set(args.dropFirst(2).suffix(2))
switch args[1] {
case "run" where args.count >= 4:
    let tag = env["MESSAGES_CHECK_TAG"] ?? "Latchkey check msgcheck"
    do {
        try await run(own: args[2], number: args[3], tag: tag)
    } catch {
        print("FAILED: \((error as? CheckFailure)?.message ?? (error as? MessagesWindowProblem)?.message ?? "\(error)")")
        exit(1)
    }
case "read":
    // read <conversation id>: what the store makes of a real conversation (tapbacks, edits, replies).
    for m in try store().messages(in: args[2], before: nil, limit: 30) {
        print(
            "\(m.id) \(m.fromMe ? "me" : "them") «\(m.text.prefix(60))» edited=\(m.edited) first=\(m.originalText ?? "-") unsent=\(m.unsent) reply=\(m.replyTo ?? "-") reactions=\(m.reactions.map { "\($0.kind)\($0.fromMe ? "(me)" : "")" })"
        )
    }
case "sweep" where args.count >= 5:
    exit(await sweep(args[2], own: [args[3], args[4]]) ? 0 : 1)
default:
    print("usage: messages-check run <own address> <own number> | sweep <tag> <own address> <own number>")
    exit(2)
}
