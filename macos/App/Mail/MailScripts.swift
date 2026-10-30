import Foundation

/// Mail's scripting, run by Latchkey itself (spec 008 plan D6). Every value travels as an
/// argument; variable names avoid Mail's terms (`.claude/rules/macos.md`).
enum MailScript {
    /// The mailbox `boxPath` of the account `acctID`, or of On My Mac.
    static let boxFor = """
        on boxFor(acctID, boxPath)
        tell application "Mail"
        try
        return mailbox boxPath of account id acctID
        on error
        return mailbox boxPath
        end try
        end tell
        end boxFor

        on lineList(theText)
        if theText is "" then return {}
        set AppleScript's text item delimiters to linefeed
        set theItems to text items of theText
        set AppleScript's text item delimiters to ""
        return theItems
        end lineList
        """

    /// argv: "launch" to start Mail if needed (else nothing when it isn't running). One line per
    /// account: id, name, type, enabled, addresses (comma-separated), its Sent mailbox's name.
    static let accounts = """
        on run argv
        if item 1 of argv is not "launch" then
        if application "Mail" is not running then return ""
        end if
        tell application "Mail"
        set sentPairs to {}
        repeat with theBox in (mailboxes of sent mailbox)
        set end of sentPairs to {(id of account of theBox), (name of theBox)}
        end repeat
        set out to ""
        repeat with acct in every account
        set acctID to id of acct
        set sentName to ""
        repeat with thePair in sentPairs
        if (item 1 of thePair) is acctID then set sentName to item 2 of thePair
        end repeat
        set AppleScript's text item delimiters to ","
        set addrText to (email addresses of acct) as text
        set AppleScript's text item delimiters to ""
        set out to out & acctID & tab & (name of acct) & tab & (account type of acct as text) & tab & (enabled of acct as text) & tab & addrText & tab & sentName & linefeed
        end repeat
        return out
        end tell
        end run
        """

    /// argv: action, target mailbox path (for move), then account id, mailbox path, message id for
    /// each message. One line per message: "ok <id>", "missing <id>", or "failed <id> <why>".
    static let change =
        """
        on run argv
        set theAction to item 1 of argv
        set targetPath to item 2 of argv
        set out to ""
        tell application "Mail"
        repeat with i from 3 to (count of argv) by 3
        set acctID to item i of argv
        set boxPath to item (i + 1) of argv
        set msgID to (item (i + 2) of argv) as integer
        set theMsg to missing value
        try
        set theMsg to (first message of (my boxFor(acctID, boxPath)) whose id is msgID)
        end try
        if theMsg is missing value then
        set out to out & "missing " & msgID & linefeed
        else
        try
        if theAction is "mark_read" then
        set read status of theMsg to true
        else if theAction is "mark_unread" then
        set read status of theMsg to false
        else if theAction is "flag" then
        set flagged status of theMsg to true
        else if theAction is "unflag" then
        set flagged status of theMsg to false
        else if theAction is "junk" then
        set junk mail status of theMsg to true
        else if theAction is "not_junk" then
        set junk mail status of theMsg to false
        else if theAction is "move" then
        move theMsg to (my boxFor(acctID, targetPath))
        else if theAction is "delete" then
        set trashBox to missing value
        repeat with theBox in (mailboxes of trash mailbox)
        if (id of account of theBox) is acctID then set trashBox to contents of theBox
        end repeat
        if trashBox is missing value then error "its account has no Trash mailbox"
        move theMsg to trashBox
        end if
        set out to out & "ok " & msgID & linefeed
        on error errText
        set out to out & "failed " & msgID & " " & errText & linefeed
        end try
        end if
        end repeat
        end tell
        return out
        end run

        """ + boxFor

    /// argv: mode (send, draft), kind (new, reply, replyall, forward), account id, mailbox path and
    /// id of the original, sender ("Name <address>"), the sender's address, subject, text, then
    /// newline-separated to, cc, bcc, files, and the original's attachments for a forward (added
    /// only when Mail's forward has none after the text is set). Returns "sent", "saved", or
    /// "sender <what Mail used>" when Mail didn't take the sender (nothing sent).
    static let compose =
        """
        on run argv
        set theMode to item 1 of argv
        set theKind to item 2 of argv
        set acctID to item 3 of argv
        set boxPath to item 4 of argv
        set origID to item 5 of argv
        set senderText to item 6 of argv
        set senderAddr to item 7 of argv
        set theSubject to item 8 of argv
        set theBody to item 9 of argv
        set toList to my lineList(item 10 of argv)
        set ccList to my lineList(item 11 of argv)
        set bccList to my lineList(item 12 of argv)
        set fileList to my lineList(item 13 of argv)
        set origFiles to my lineList(item 14 of argv)
        tell application "Mail"
        if theKind is "new" then
        set theMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
        else
        set origMsg to (first message of (my boxFor(acctID, boxPath)) whose id is (origID as integer))
        if theKind is "reply" then
        set theMsg to reply origMsg without opening window
        else if theKind is "replyall" then
        set theMsg to reply origMsg without opening window with reply to all
        else
        set theMsg to forward origMsg without opening window
        end if
        set content of theMsg to theBody
        if theSubject is not "" then set subject of theMsg to theSubject
        end if
        if senderText is not "" then set sender of theMsg to senderText
        repeat with addr in toList
        make new to recipient at end of to recipients of theMsg with properties {address:(contents of addr)}
        end repeat
        repeat with addr in ccList
        make new cc recipient at end of cc recipients of theMsg with properties {address:(contents of addr)}
        end repeat
        repeat with addr in bccList
        make new bcc recipient at end of bcc recipients of theMsg with properties {address:(contents of addr)}
        end repeat
        set wantedFiles to fileList
        if theKind is "forward" and (count of origFiles) > 0 then
        if (count of attachments of content of theMsg) is 0 then set wantedFiles to origFiles & fileList
        end if
        if (count of wantedFiles) > 0 then
        set expected to (count of attachments of content of theMsg) + (count of wantedFiles)
        tell content of theMsg
        repeat with theFile in wantedFiles
        make new attachment with properties {file name:(POSIX file (contents of theFile))} at after the last paragraph
        end repeat
        end tell
        set waitUntil to (current date) + 15
        repeat while (count of attachments of content of theMsg) < expected and (current date) < waitUntil
        delay 0.5
        end repeat
        end if
        set usedSender to (sender of theMsg) as text
        if senderAddr is not "" and usedSender does not contain senderAddr then
        try
        close theMsg saving no
        end try
        return "sender " & usedSender
        end if
        if theMode is "draft" then
        save theMsg
        close theMsg saving yes
        return "saved"
        end if
        send theMsg
        return "sent"
        end tell
        end run

        """ + boxFor

    /// argv: account id, mailbox path, message id, attachment name, destination file. Mail
    /// downloads the attachment if needed and saves it as that file, whose name Latchkey chose:
    /// the sender's name is only compared, never part of the path (plan D5).
    static let saveAttachment =
        """
        on run argv
        set acctID to item 1 of argv
        set boxPath to item 2 of argv
        set msgID to (item 3 of argv) as integer
        set attName to item 4 of argv
        set destFile to item 5 of argv
        tell application "Mail"
        set theMsg to (first message of (my boxFor(acctID, boxPath)) whose id is msgID)
        repeat with theAttachment in (mail attachments of theMsg)
        if (name of theAttachment) is attName then
        save theAttachment in (POSIX file destFile)
        return "saved"
        end if
        end repeat
        end tell
        return "missing"
        end run

        """ + boxFor
}

/// Mail's accounts as its scripting reports them, kept 10 minutes (plan D2).
final class MailAccounts: @unchecked Sendable {
    struct Account: Sendable, Equatable {
        var id: String
        var name: String
        var kind: String
        var enabled: Bool
        var addresses: [String]
        var sentName: String?

        var label: String {
            let first = addresses.first ?? ""
            return first.isEmpty || first.caseInsensitiveCompare(name) == .orderedSame ? name : "\(name) (\(first))"
        }
    }

    private let scripts: any ScriptRunner
    private let mayScript: @Sendable () -> Bool
    private let lock = NSLock()
    private var cached: (at: Date, list: [Account])?

    init(scripts: any ScriptRunner, mayScript: @escaping @Sendable () -> Bool) {
        self.scripts = scripts
        self.mayScript = mayScript
    }

    /// The accounts, from the cache or Mail; nil when Mail can't be asked. `launch` starts Mail
    /// (for changes and sending); reading never does and never prompts.
    func list(launch: Bool) async -> [Account]? {
        if let c = lock.withLock({ cached }), Date().timeIntervalSince(c.at) < 600 { return c.list }
        guard launch || mayScript() else { return nil }
        guard let out = try? await scripts.run(MailScript.accounts, [launch ? "launch" : "if running"]) else {
            return nil
        }
        let list = Self.parse(out)
        guard !list.isEmpty else { return nil }
        lock.withLock { cached = (Date(), list) }
        return list
    }

    static func parse(_ out: String) -> [Account] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, !f[0].isEmpty else { return nil }
            return Account(
                id: f[0], name: f[1], kind: f[2], enabled: f[3] == "true",
                addresses: f[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                sentName: f[5].isEmpty ? nil : f[5])
        }
    }
}
