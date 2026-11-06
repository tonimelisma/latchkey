// Runs Latchkey's real compose code (MailCompose + AXMailWindows) against the real Mail, from a
// terminal that has Accessibility, in whatever screen state the Mac is in (unlocked, locked, lid
// closed). Built by mail-check.sh. Usage: mail-check <to> <draft|send|probe>
//   draft: saves a draft; send: sends; probe: opens a window, prints what Accessibility shows for
//   each recipient and every field, and closes it unsent.
// MAIL_CHECK_NAME: the name Mail shows for <to> (it shows names, not addresses, for known people);
// MAIL_CHECK_FILE: a file to attach.
import AppKit
import Foundation

/// Every attribute of each recipient token in the To field, to see whether one holds the address.
func probe(_ w: AXComposeWindow) {
    guard let field = AX.find(w.window, depth: 4, { AX.string($0, "AXIdentifier") == "Mail.toField" }) else {
        print("no To field")
        return
    }
    for (i, token) in AX.children(field).enumerated() {
        var names: CFArray?
        AXUIElementCopyAttributeNames(token, &names)
        for name in (names as? [String]) ?? [] {
            print("token \(i) \(name) = \(AX.value(token, name).map { "\($0)" } ?? "nil")")
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 3, ["draft", "send", "probe", "script"].contains(args[2]) else {
    print("usage: mail-check <to> <draft|send|probe|script>")
    exit(2)
}
if args[2] == "script" {
    let finished = DispatchSemaphore(value: 0)
    let result = ScriptedResult()
    Task {
        result.ok = await scriptedCheck(to: args[1])
        finished.signal()
    }
    while finished.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(result.ok ? 0 : 1)
}
let to = args[1]
let draft = args[2] == "draft"
let env = ProcessInfo.processInfo.environment
let subject = "Latchkey check: compose \(args[2]) \(ISO8601DateFormatter().string(from: Date()))"
guard let url = MailCompose.mailto(to: [to], cc: [], bcc: [], subject: subject) else {
    print("no mailto")
    exit(1)
}
let request = MailCompose.Request(
    opening: .new(mailto: url), to: [KnownAddress(address: to, names: env["MAIL_CHECK_NAME"].map { [$0] } ?? [])],
    subject: subject, text: "Automated Latchkey check, please ignore.\nSecond line.",
    files: env["MAIL_CHECK_FILE"].map { [URL(filePath: $0)] } ?? [], draft: draft)

let done = DispatchSemaphore(value: 0)
Task {
    do {
        if args[2] == "probe" {
            let windows = AXMailWindows(scripts: HarnessScripts())
            let w = try await windows.open(.new(mailto: url))
            if let ax = w as? AXComposeWindow { probe(ax) }
            print("fields: \(try await w.fields())")
            print(await w.discard() ? "closed unsent" : "COULD NOT CLOSE")
            await windows.finish()
        } else {
            let shown = try await MailCompose.run(request, AXMailWindows(scripts: HarnessScripts()))
            print("OK: \(draft ? "saved" : "sent") «\(shown)»")
        }
    } catch let f as ComposeFailure {
        print("FAILED: \(f.message)")
    } catch {
        print("FAILED: \(error)")
    }
    // The check's own email never stays in the Owner's mailboxes (Toni, 2026-11-02): every copy
    // with its subject (sent, received, draft) is marked read and moved to Deleted Items as it
    // arrives, for up to 90 s.
    if args[2] != "probe" {
        let cleanup = """
            on run argv
            set theSubject to item 1 of argv
            set n to 0
            tell application "Mail"
            repeat with acct in accounts
            repeat with box in mailboxes of acct
            set boxName to name of box
            if boxName is not "Deleted Items" and boxName is not "Trash" and boxName is not "Deleted Messages" then
            try
            set found to (get messages of box whose subject is theSubject)
            repeat with m in found
            set read status of m to true
            delete m
            set n to n + 1
            end repeat
            end try
            end if
            end repeat
            end repeat
            end tell
            return n as text
            end run
            """
        var removed = 0
        for _ in 0..<9 {
            let n = Int((try? await HarnessScripts().run(cleanup, [subject]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            removed += n
            if removed >= (draft ? 1 : 2) { break }
            try? await Task.sleep(for: .seconds(10))
        }
        print("cleaned up: \(removed) cop\(removed == 1 ? "y" : "ies") marked read and moved to Deleted Items")
    }
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
