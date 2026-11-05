import Foundation

/// Email written by Mail's scripting with no window, its text carried in by a Mail signature that
/// exists for about a second (spec 008 plan D6a, FR-841 to FR-845). Text set as a message's
/// `content` arrives marked as quoted in other mail apps (research "Live check", FB11734014); a
/// signature's text is put in by Mail's own composer and arrives as ordinary text, above Mail's
/// quote in a reply or forward (checked live 2026-11-05). Needs no window, so it works while the
/// Mac is locked, and no Accessibility. Every recipient, the subject, and the From are read back
/// by scripting, as addresses, and checked as in Mail's window (`MailCompose.check`) before Send.
enum MailSignatureWriter {
    /// The name of every signature Latchkey makes starts with this; one left behind by a write
    /// that was cut off (Mail or Latchkey quitting meanwhile) is removed by the next write.
    static let signaturePrefix = "Latchkey message "

    /// argv: kind (new, reply, replyAll, forward), the original's account id, mailbox path, and id
    /// (responses), the subject (new), the sender or "", a fresh signature name, the text, then
    /// pairs: "to"/"cc"/"bcc" and an address, or "file" and a path. Prints Mail's own recipients
    /// ("before …"), then the outgoing message's id, subject, From, and every recipient.
    static let makeScript = """
        on run argv
        set theKind to item 1 of argv
        set sigPrefix to "\(signaturePrefix)"
        set sigName to sigPrefix & (item 7 of argv)
        set theText to item 8 of argv
        set out to ""
        tell application "Mail"
        try
        repeat with n in (name of every signature)
        if (n as text) starts with sigPrefix then delete signature (n as text)
        end repeat
        end try
        if theKind is "new" then
        set m to make new outgoing message with properties {subject:(item 5 of argv), visible:false}
        else
        try
        set theBox to mailbox (item 3 of argv) of account id (item 2 of argv)
        on error
        set theBox to mailbox (item 3 of argv)
        end try
        set theMsg to (first message of theBox whose id is ((item 4 of argv) as integer))
        if theKind is "reply" then
        set m to reply theMsg opening window false
        else if theKind is "replyAll" then
        set m to reply theMsg opening window false with reply to all
        else
        set m to forward theMsg opening window false
        end if
        end if
        try
        repeat with r in (to recipients of m)
        set out to out & "before to " & (address of r) & linefeed
        end repeat
        repeat with r in (cc recipients of m)
        set out to out & "before cc " & (address of r) & linefeed
        end repeat
        repeat with r in (bcc recipients of m)
        set out to out & "before bcc " & (address of r) & linefeed
        end repeat
        if (item 6 of argv) is not "" then set sender of m to (item 6 of argv)
        set theFiles to {}
        repeat with i from 9 to (count of argv) by 2
        set theField to item i of argv
        set theValue to item (i + 1) of argv
        if theField is "to" then
        tell m to make new to recipient at end of to recipients with properties {address:theValue}
        else if theField is "cc" then
        tell m to make new cc recipient at end of cc recipients with properties {address:theValue}
        else if theField is "bcc" then
        tell m to make new bcc recipient at end of bcc recipients with properties {address:theValue}
        else
        set end of theFiles to theValue
        end if
        end repeat
        if theText is not "" then
        set theSignature to make new signature with properties {name:sigName, content:theText}
        set message signature of m to theSignature
        -- Mail puts the signature's text in a moment later.
        delay 1
        end if
        repeat with f in theFiles
        tell content of m to make new attachment with properties {file name:(POSIX file (f as text))} at after the last paragraph
        end repeat
        try
        delete signature sigName
        end try
        set out to out & "id " & (id of m) & linefeed
        set out to out & "subject " & (subject of m) & linefeed
        set out to out & "from " & (sender of m) & linefeed
        repeat with r in (to recipients of m)
        set out to out & "to " & (address of r) & linefeed
        end repeat
        repeat with r in (cc recipients of m)
        set out to out & "cc " & (address of r) & linefeed
        end repeat
        repeat with r in (bcc recipients of m)
        set out to out & "bcc " & (address of r) & linefeed
        end repeat
        on error errText number errNum
        try
        delete signature sigName
        end try
        try
        close m saving no
        end try
        error errText number errNum
        end try
        end tell
        return out
        end run
        """

    /// argv: the outgoing message's id, then "send", "save" (a draft), or "close" (discard).
    static let finishScript = """
        on run argv
        set theID to (item 1 of argv) as integer
        set theAction to item 2 of argv
        tell application "Mail"
        set m to first outgoing message whose id is theID
        if theAction is "send" then
        send m
        else if theAction is "save" then
        save m
        -- Mail writes the draft a moment after save; closing at once lost it (2026-11-02).
        delay 3
        close m saving no
        else
        close m saving no
        end if
        return "ok"
        end tell
        end run
        """

    struct Made: Equatable {
        var id = ""
        /// What Mail filled in on its own (a response's recipients).
        var before = ComposeFields()
        /// The message as made: subject, From, and every recipient, as addresses.
        var after = ComposeFields()
    }

    static func describe(_ e: ScriptError) -> String {
        switch e {
        case .timedOut: "it didn't answer within 25 seconds"
        case .notAllowed: "Latchkey isn't allowed to control Mail"
        case .failed(let message): message
        }
    }

    static func parse(_ out: String) -> Made {
        var m = Made()
        for line in out.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            switch key {
            case "before":
                let f = value.split(separator: " ", maxSplits: 1).map(String.init)
                guard f.count == 2 else { continue }
                switch f[0] {
                case "to": m.before.to.append(f[1])
                case "cc": m.before.cc.append(f[1])
                default: m.before.bcc.append(f[1])
                }
            case "id": m.id = value
            case "subject": m.after.subject = value
            case "from": m.after.from = value
            case "to": m.after.to.append(value)
            case "cc": m.after.cc.append(value)
            case "bcc": m.after.bcc.append(value)
            default: continue
            }
        }
        m.before.subject = m.after.subject
        m.before.from = m.after.from
        return m
    }

    static func arguments(_ r: MailCompose.Request, signature: String) -> [String] {
        var args: [String]
        switch r.opening {
        case .new: args = ["new", "", "", "", r.subject ?? ""]
        case .respond(_, let kind, let place):
            args = [
                kind == .reply ? "reply" : kind == .replyAll ? "replyAll" : "forward", place?.accountID ?? "",
                place?.path ?? "", place.map { String($0.id) } ?? "", "",
            ]
        }
        args += [r.sender ?? "", signature, r.text]
        for field in RecipientField.allCases {
            for a in r.requested(field) { args += [field.rawValue, a.address] }
        }
        for f in r.files { args += ["file", f.path] }
        return args
    }

    /// Makes, checks, and sends or saves the message; answers the subject Mail gave it. A
    /// failure before Send closes the message unsent; one at Send may have sent it.
    static func run(_ r: MailCompose.Request, _ scripts: any ScriptRunner) async throws -> String {
        if case .respond(_, _, nil) = r.opening {
            throw ComposeFailure(message: "Latchkey doesn't know where the original is in Mail")
        }
        let out: String
        do { out = try await scripts.run(makeScript, arguments(r, signature: UUID().uuidString)) } catch let e
            as ScriptError
        {
            throw ComposeFailure(message: "Mail couldn't make the message (\(describe(e)))")
        }
        let made = parse(out)
        guard !made.id.isEmpty else { throw ComposeFailure(message: "Mail didn't make the message") }
        do {
            // A response made by scripting is the exact message chosen; Mail's own recipients are
            // still checked against it, as in the window (security review 2026-10-30).
            if let p = r.prefill { try MailCompose.checkPrefill(p, made.before) }
            try MailCompose.check(r, prefilled: made.before, made.after, content: false)
            try Task.checkCancellation()
        } catch {
            _ = await MailCompose.uncancelled { try? await scripts.run(finishScript, [made.id, "close"]) }
            throw error
        }
        do { _ = try await scripts.run(finishScript, [made.id, r.draft ? "save" : "send"]) } catch {
            let why = (error as? ScriptError).map(describe) ?? "\(error)"
            if r.draft { throw ComposeFailure(message: "Mail didn't save the draft (\(why))") }
            throw ComposeFailure(message: "Mail was told to send it but didn't answer (\(why))", afterSend: true)
        }
        return made.after.subject
    }
}
