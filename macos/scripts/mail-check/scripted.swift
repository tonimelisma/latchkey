// The windowless writer (MailSignatureWriter, spec 008 plan D6a) against the real Mail, in whatever
// screen state the Mac is in: a new message, a draft, a reply, and a forward to <to>. Each sent
// copy is read back from Sent and must carry its text unquoted (a reply's and forward's text above
// Mail's quote). Every copy (sent, received, draft) is marked read and moved to the Trash at the
// end, even after a failure, and the check fails loudly if any is left.
import Foundation

let findScript = """
    on run argv
    set theSubject to item 1 of argv
    set theBoxes to item 2 of argv
    tell application "Mail"
    if theBoxes is "inbox" then
    set tops to {inbox}
    else
    set tops to {sent mailbox}
    end if
    repeat with top in tops
    repeat with mb in (mailboxes of top)
    try
    set found to (messages of mb whose subject is theSubject and deleted status is false)
    if (count of found) > 0 then
    set m to item 1 of found
    if theBoxes is "inbox" then return (id of account of mb) & tab & (name of mb) & tab & (id of m)
    return source of m
    end if
    end try
    end repeat
    end repeat
    end tell
    return ""
    end run
    """

/// Marks read and moves to its account's Trash every copy whose subject contains the tag;
/// answers how many are still outside a Trash.
let sweepScript = """
    on run argv
    set theTag to item 1 of argv
    tell application "Mail"
    repeat with top in {inbox, sent mailbox, drafts mailbox}
    repeat with mb in (mailboxes of top)
    try
    set acct to account of mb
    set trashBox to missing value
    repeat with t in (mailboxes of trash mailbox)
    if (id of account of t) is (id of acct) then set trashBox to contents of t
    end repeat
    set found to (messages of mb whose subject contains theTag)
    repeat with m in found
    set read status of m to true
    if (name of mb) is "Drafts" or trashBox is missing value then
    delete m
    else
    move m to trashBox
    end if
    end repeat
    end try
    end repeat
    end repeat
    delay 3
    set n to 0
    repeat with top in {inbox, sent mailbox, drafts mailbox}
    repeat with mb in (mailboxes of top)
    try
    set n to n + (count of (messages of mb whose subject contains theTag and deleted status is false))
    end try
    end repeat
    end repeat
    end tell
    return n as text
    end run
    """

final class ScriptedResult: @unchecked Sendable { var ok = false }

func poll(_ subject: String, _ boxes: String) async -> String {
    for _ in 0..<12 {
        let out = ((try? await HarnessScripts().run(findScript, [subject, boxes])) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        try? await Task.sleep(for: .seconds(10))
    }
    return ""
}

/// The sent copy's text lines (plain part, as Mail wrote them).
func sentLines(_ subject: String) async -> [String] {
    (await poll(subject, "sent")).components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
}

func scriptedCheck(to: String) async -> Bool {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let tag = "Latchkey check: script \(stamp)"
    let k = KnownAddress(address: to)
    var failures: [String] = []
    func step(_ name: String, _ r: MailCompose.Request) async {
        do {
            let shown = try await MailSignatureWriter.run(r, HarnessScripts())
            print("OK: \(name) «\(shown)»")
        } catch let f as ComposeFailure {
            failures.append("\(name): \(f.message)")
        } catch {
            failures.append("\(name): \(error)")
        }
    }
    let newText = "Automated Latchkey check, please ignore.\nSecond line."
    if let url = MailCompose.mailto(to: [to], cc: [], bcc: [], subject: tag) {
        await step("send", .init(opening: .new(mailto: url), to: [k], subject: tag, text: newText, files: [], draft: false))
    }
    if let url = MailCompose.mailto(to: [to], cc: [], bcc: [], subject: "\(tag) draft") {
        await step(
            "draft",
            .init(opening: .new(mailto: url), to: [k], subject: "\(tag) draft", text: "Draft line.", files: [], draft: true))
    }
    let place = (await poll(tag, "inbox")).split(separator: "\t").map(String.init)
    if place.count == 3, let id = Int64(place[2]) {
        let at = MessagePlace(accountID: place[0], path: place[1], id: id)
        await step(
            "reply",
            .init(
                opening: .respond(messageID: "", kind: .reply, place: at),
                prefill: ResponsePrefill(subject: tag, allowed: [k], required: [k], own: [k]), own: [k],
                text: "Reply line.", files: [], draft: false))
        await step(
            "forward",
            .init(
                opening: .respond(messageID: "", kind: .forward, place: at), to: [k],
                prefill: ResponsePrefill(subject: tag, own: [k], attachments: []), own: [k],
                text: "Forward line.", files: [], draft: false))
    } else {
        failures.append("the new message didn't arrive in the Inbox in 2 minutes")
    }
    // Each sent copy carries its text unquoted, a response's above Mail's quote.
    for (subject, line, quoted) in [
        (tag, "Second line.", false), ("Re: \(tag)", "Reply line.", true), ("Fwd: \(tag)", "Forward line.", true),
    ] {
        let lines = await sentLines(subject)
        guard let at = lines.firstIndex(of: line) else {
            failures.append("«\(subject)»: its sent copy has no unquoted line «\(line)»")
            continue
        }
        if lines.contains("> \(line)") { failures.append("«\(subject)»: its text arrived quoted") }
        if quoted, !(lines[at...].contains { $0.hasPrefix(">") }) {
            failures.append("«\(subject)»: Mail's quote isn't below the text")
        }
    }
    // The received copies too, before the sweep.
    for subject in ["Re: \(tag)", "Fwd: \(tag)"] { _ = await poll(subject, "inbox") }
    // Cleanup, whatever happened above.
    var left = -1
    for _ in 0..<9 {
        left = Int(((try? await HarnessScripts().run(sweepScript, [tag])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        if left == 0 { break }
        try? await Task.sleep(for: .seconds(10))
    }
    if left != 0 { failures.append("LEFT BEHIND: \(left) copies of «\(tag)» outside the Trash") }
    for f in failures { print("FAILED: \(f)") }
    print(failures.isEmpty ? "OK: all four written, arrived unquoted, and cleaned up" : "FAILED")
    return failures.isEmpty
}
