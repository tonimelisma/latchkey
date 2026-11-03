import Foundation

/// Organising through Mail's scripting; drafts and sending in Mail's own compose window (spec 008 plan D6, D7).
enum MailWrite {
    typealias Env = MailCapability.Env

    static func q(_ s: String) -> String { MailCapability.q(s) }

    struct Outcome {
        var done: [MailStore.Summary] = []
        var problems: [String] = []
    }

    /// Runs the change script for messages, each addressed through its place (plan D6).
    static func act(_ action: String, _ messages: [MailStore.Summary], target: String, _ env: Env) async throws
        -> Outcome
    {
        var args = [action, target]
        for m in messages { args += [m.place.accountID, m.place.path, String(m.id)] }
        let out = try await env.scripts.run(MailScript.change, args)
        var outcome = Outcome()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let id = Int64(parts[1]) else { continue }
            switch parts[0] {
            case "ok": if let m = messages.first(where: { $0.id == id }) { outcome.done.append(m) }
            case "missing":
                outcome.problems.append("message \(id) is no longer where it was (moved or deleted); find it again")
            default: outcome.problems.append("message \(id): \(parts.count > 2 ? parts[2] : "Mail refused")")
            }
        }
        return outcome
    }

    // MARK: mail_change

    static func change(_ args: JSONValue, _ s: MailStore, _ env: Env) async throws -> ToolResult {
        let action = args["action"]?.stringValue ?? ""
        guard MailCapability.changeActions.contains(action) else {
            return .unknown("action", action.isEmpty ? nil : action, allowed: MailCapability.changeActions)
        }
        if action == "draft" { return try await compose(args, s, env, draft: true) }
        var raw: [String] = []
        if let id = args["id"]?.stringValue, !id.isEmpty { raw.append(id) }
        if case .array(let list)? = args["ids"] { raw += list.compactMap(\.stringValue) }
        guard !raw.isEmpty else { return .text("Give the message's id, or ids for several.", isError: true) }
        var messages: [MailStore.Summary] = []
        var problems: [String] = []
        for r in raw {
            let id = try MailCapability.messageID(r)
            do { messages.append(try s.message(id)) } catch MailStore.Failure.noSuchMessage {
                problems.append("there is no message with id \(id)")
            }
        }
        var done: [MailStore.Summary] = []
        var target = ""
        if action == "move" {
            guard let name = args["mailbox"]?.stringValue, !name.isEmpty else {
                return .text("Say which mailbox to move to.", isError: true)
            }
            for account in Set(messages.map(\.mailbox.accountID)) {
                let group = messages.filter { $0.mailbox.accountID == account }
                let boxes = try s.mailboxes(named: name, accounts: [account])
                guard let box = boxes.first else {
                    let all = try s.mailboxes().filter { $0.accountID == account }.map(\.path)
                    problems.append(
                        "its account has no mailbox \(name) (it has: \(all.joined(separator: ", "))); \(group.count) not moved"
                    )
                    continue
                }
                target = box.path
                let o = try await act(action, group, target: box.path, env)
                done += o.done
                problems += o.problems
            }
        } else if !messages.isEmpty {
            let o = try await act(action, messages, target: "", env)
            done = o.done
            problems += o.problems
        }
        let verb: String =
            switch action {
            case "mark_read": "Marked read"
            case "mark_unread": "Marked unread"
            case "flag": "Flagged"
            case "unflag": "Unflagged"
            case "junk": "Marked as junk"
            case "not_junk": "Marked as not junk"
            case "delete": "Moved to its account's Trash"
            default: "Moved to \(target)"
            }
        var lines: [String] = []
        if !done.isEmpty {
            lines.append("\(verb): " + done.map { "\(q($0.subject)) (id \($0.id))" }.joined(separator: ", ") + ".")
        }
        if !problems.isEmpty { lines.append("Not done: " + problems.joined(separator: "; ") + ".") }
        var r = ToolResult.text(lines.joined(separator: "\n"), isError: done.isEmpty)
        if !done.isEmpty {
            let what = done.count == 1 ? "«\(done[0].subject)»" : "\(done.count) emails"
            r.activity =
                switch action {
                case "delete": "Claude moved \(what) to Trash"
                case "move": "Claude moved \(what) to \(target)"
                case "junk": "Claude marked \(what) as junk"
                case "not_junk": "Claude marked \(what) as not junk"
                case "mark_read": "Claude marked \(what) read"
                case "mark_unread": "Claude marked \(what) unread"
                case "flag": "Claude flagged \(what)"
                default: "Claude unflagged \(what)"
                }
        }
        return r
    }

    // MARK: composing

    static func send(_ args: JSONValue, _ s: MailStore, _ env: Env) async throws -> ToolResult {
        try await compose(args, s, env, draft: false)
    }

    static func addresses(_ args: JSONValue, _ key: String) throws -> [String] {
        guard let v = args[key], v != .null else { return [] }
        let list: [String]
        switch v {
        case .array(let a): list = a.compactMap(\.stringValue)
        case .string(let one): list = one.split(separator: ",").map(String.init)
        default: throw ArgumentError(message: "\(key) must be a list of email addresses.")
        }
        let clean = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for a in clean where !a.contains("@") || a.contains(" ") && !a.contains("<") {
            throw ArgumentError(message: "\(a) in \(key) isn't an email address. Find addresses with contacts_find.")
        }
        return clean
    }

    /// The address inside "Name <address>", or the text itself.
    static func bare(_ a: String) -> String {
        guard let open = a.lastIndex(of: "<"), let close = a.lastIndex(of: ">"), open < close else {
            return a.trimmingCharacters(in: .whitespaces)
        }
        return String(a[a.index(after: open)..<close])
    }

    /// What Mail's Reply, Reply All, or Forward of this message fills in, from the store and the
    /// message's file (security review 2026-10-30). Reply goes to Reply-To when there is one,
    /// else to the sender, and for a message the Owner sent, to its recipients; Reply All adds
    /// the original's To and Cc; Forward fills in no one and carries the original's attachments.
    static func expectedPrefill(
        _ m: MailStore.Summary, _ kind: ResponseKind, _ s: MailStore, own: [KnownAddress],
        known: (String, [String]) -> KnownAddress
    ) throws -> ResponsePrefill {
        var p = ResponsePrefill(subject: m.subject, own: own)
        if kind == .forward {
            p.attachments = try s.attachmentParts(m.id).map(\.name)
            return p
        }
        let recipients = try s.recipients(m.id)
        // Without the file, Reply-To is unknown: only the sender counts, and a window addressed
        // elsewhere is refused.
        let replyTo = s.file(for: m).flatMap { try? MailFile.read($0) }?.replyTo ?? []
        var targets = replyTo.map { known($0.address, [$0.name]) } + [known(m.senderAddress, [m.senderName])]
        if own.contains(where: { $0.matches(m.senderAddress) }) {
            targets += recipients.filter { $0.kind == .to }.map { known($0.address, [$0.name]) }
        }
        p.required = targets
        p.allowed = targets
        if kind == .replyAll {
            p.allowed += recipients.filter { $0.kind != .bcc }.map { known($0.address, [$0.name]) }
        }
        return p
    }

    /// A new message, reply, or forward written in Mail's own window (plan D6, Toni 2026-10-30),
    /// then sent and confirmed in Sent (plan D7), or saved as a draft.
    static func compose(_ args: JSONValue, _ s: MailStore, _ env: Env, draft: Bool) async throws -> ToolResult {
        let to = try addresses(args, "to")
        let cc = try addresses(args, "cc")
        let bcc = try addresses(args, "bcc")
        let text = args["text"]?.stringValue ?? ""
        let subject = args["subject"]?.stringValue ?? ""
        var original: MailStore.Summary?
        var kind: ResponseKind?
        if let r = args["reply_to"]?.stringValue, !r.isEmpty {
            original = try s.message(try MailCapability.messageID(r))
            kind = args["reply_all"]?.boolValue == true ? .replyAll : .reply
        } else if let f = args["forward"]?.stringValue, !f.isEmpty {
            original = try s.message(try MailCapability.messageID(f))
            kind = .forward
        }
        let nothing = draft ? "No draft was saved" : "Nothing was sent"
        if !draft {
            if kind == nil || kind == .forward, to.isEmpty, cc.isEmpty, bcc.isEmpty {
                return .text("\(nothing): say who to send it to (to).", isError: true)
            }
            if kind == nil, subject.isEmpty { return .text("\(nothing): give a subject.", isError: true) }
        }
        var files: [URL] = []
        if case .array(let list)? = args["attachments"] {
            for p in list.compactMap(\.stringValue) {
                let url = URL(filePath: (p as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                    FileManager.default.isReadableFile(atPath: url.path)
                else { return .text("\(nothing): there's no readable file at \(p).", isError: true) }
                files.append(url)
            }
        }
        // The sending account (FR-822).
        let accounts = try await MailCapability.accounts(s, env, launch: true)
        var account: MailCapability.AccountInfo?
        var sender: String?
        if let original {
            account = accounts.first { $0.id == original.mailbox.accountID }
            let received = try s.recipients(original.id).map { $0.address.lowercased() }
            sender = account?.addresses.first { received.contains($0.lowercased()) } ?? account?.addresses.first
        } else if let from = args["from"]?.stringValue, !from.isEmpty {
            guard let a = MailCapability.account(named: bare(from), in: accounts), !a.addresses.isEmpty else {
                return .text(
                    "\(nothing): \(from) isn't one of Mail's accounts. Accounts: \(accounts.filter { !$0.addresses.isEmpty }.map(\.label).joined(separator: "; ")).",
                    isError: true)
            }
            account = a
            sender = a.addresses.first { $0.caseInsensitiveCompare(bare(from)) == .orderedSame } ?? a.addresses[0]
        }
        // What Mail may show for an address: the address, a name it came with, the contact's name,
        // or, for one of the Owner's own addresses, the account's full name (Mail shows that,
        // seen live 2026-11-01: "Toni Melisma" for the Owner's own address, which Contacts lacked).
        func known(_ address: String, _ names: [String] = []) -> KnownAddress {
            let a = bare(address)
            let given = address.firstIndex(of: "<").map { [String(address[..<$0])] } ?? []
            let accountNames = accounts.filter {
                $0.addresses.contains { $0.caseInsensitiveCompare(a) == .orderedSame }
            }
            .compactMap(\.fullName)
            let all = (names + given + [env.contacts.name(for: a.lowercased())].compactMap { $0 } + accountNames)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.filter { !$0.isEmpty }
            return KnownAddress(address: a, names: all)
        }
        let own = accounts.flatMap(\.addresses).map { known($0) }
        let opening: ComposeOpening
        var prefill: ResponsePrefill?
        if let original, let kind {
            guard let messageID = try s.messageIDHeader(original.id), !messageID.isEmpty else {
                return .text(
                    "\(nothing): Mail has no Message-ID for that message, so it can't be opened.", isError: true)
            }
            // Mail opens the original by its Message-ID, which anyone can copy into a message of
            // their own (security review 2026-10-30): with two, the wrong one could open.
            let sharing = try s.messagesSharing(messageID: messageID)
            if sharing > 1 {
                return .text(
                    "\(nothing): \(sharing) messages in Mail have that message's Message-ID \(messageID), so Latchkey can't be sure Mail would open the one chosen. Answer it in Mail instead.",
                    isError: true)
            }
            opening = .respond(
                messageID: messageID, kind: kind,
                place: MessagePlace(accountID: original.place.accountID, path: original.place.path, id: original.id))
            prefill = try expectedPrefill(original, kind, s, own: own, known: known)
        } else {
            guard let url = MailCompose.mailto(to: to, cc: cc, bcc: bcc, subject: subject) else {
                return .text("\(nothing): those addresses can't go into a new message.", isError: true)
            }
            opening = .new(mailto: url)
        }
        let request = MailCompose.Request(
            opening: opening, to: to.map { known($0) }, cc: cc.map { known($0) }, bcc: bcc.map { known($0) },
            subject: kind == nil ? subject : nil, prefill: prefill, own: own, sender: sender, text: text,
            files: files, draft: draft)
        let start = Date().addingTimeInterval(-2)
        let shownSubject: String
        do {
            shownSubject = try await env.composeQueue.run {
                try await MailCompose.run(request, env.windows, attachWait: env.attachWait)
            }
        } catch let f as ComposeFailure where f.afterSend {
            return .text(
                "Mail may not have sent it: \(f.message). Check Sent (mail_find, mailbox Sent) before sending it again.",
                isError: true)
        } catch let f as ComposeFailure {
            let why = f.message.hasPrefix("Nothing was sent") ? f.message : "\(nothing): \(f.message)"
            return .text(
                draft ? why.replacingOccurrences(of: "Nothing was sent", with: "No draft was saved") : why,
                isError: true)
        } catch is CancellationError {
            return .text("\(nothing): the request was stopped before it went.", isError: true)
        }
        let finalSubject = shownSubject.isEmpty ? subject : shownSubject
        let who = (to + cc + bcc).first ?? (kind == .forward ? "" : original?.senderAddress ?? "")
        if draft {
            var r = ToolResult.text(
                "Saved a draft\(who.isEmpty ? "" : " to \(who)"): \(q(finalSubject)), in \(account?.label ?? "the account")'s Drafts."
            )
            r.activity = "Claude saved a draft\(who.isEmpty ? "" : " to \(who)"): «\(finalSubject)»"
            r.made = "the draft «\(finalSubject)» in Mail"
            return r
        }
        // FR-823: confirmed in the account's Sent mailbox.
        let boxes = try s.mailboxes().filter { b in
            (account.map { $0.id == b.accountID } ?? true)
                && (account?.sentName.map { b.name.caseInsensitiveCompare($0) == .orderedSame }
                    ?? MailStore.looksSent(b.name))
        }
        var copy: (id: Int64, messageID: String?, attachments: Int)?
        let deadline = ContinuousClock.now + env.confirmWait
        while copy == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            copy = try s.sentCopy(in: boxes, since: start, subject: finalSubject, recipient: bare(who))
            if copy == nil { try? await Task.sleep(for: env.poll) }
        }
        let fileNote = files.isEmpty ? "" : ", \(files.count) attachment\(files.count == 1 ? "" : "s")"
        var r: ToolResult
        if let copy {
            var line = "Sent to \(([who] + (to + cc + bcc).dropFirst()).joined(separator: ", "))"
            if let sender { line += " from \(sender)" }
            line +=
                ": \(q(finalSubject))\(fileNote). It is in Sent (Message-ID \(copy.messageID ?? "unknown"), id \(copy.id))."
            if copy.attachments < files.count {
                line +=
                    " But the copy in Sent shows \(copy.attachments) attachment\(copy.attachments == 1 ? "" : "s"), not \(files.count): check it in Mail before sending again."
            }
            r = .text(line)
        } else {
            r = .text(
                "Mail sent the message to \(who): \(q(finalSubject))\(fileNote), but its copy isn't in Sent yet. Don't send it again; check with mail_find (mailbox Sent) in a minute."
            )
        }
        r.activity = "Claude sent an email to \(who): «\(finalSubject)»"
        return r
    }
}
