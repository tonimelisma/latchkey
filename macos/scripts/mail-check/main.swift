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
guard args.count >= 3, ["draft", "send", "probe"].contains(args[2]) else {
    print("usage: mail-check <to> <draft|send|probe>")
    exit(2)
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
            let windows = AXMailWindows()
            let w = try await windows.open(.new(mailto: url))
            if let ax = w as? AXComposeWindow { probe(ax) }
            print("fields: \(try await w.fields())")
            print(await w.discard() ? "closed unsent" : "COULD NOT CLOSE")
            await windows.finish()
        } else {
            let shown = try await MailCompose.run(request, AXMailWindows())
            print("OK: \(draft ? "saved" : "sent") «\(shown)»")
        }
    } catch let f as ComposeFailure {
        print("FAILED: \(f.message)")
    } catch {
        print("FAILED: \(error)")
    }
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
