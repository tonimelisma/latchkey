import Foundation

/// Sign-in (spec 013, contract `contracts/login-tools.md`): Claude lists the sites Latchkey can
/// sign in to, and asks Latchkey to type a saved user name, password, or code into a field of one
/// of its own pages and press the button Claude names. Latchkey types the secret; Claude never
/// sees it, and Claude reads the page and decides what happened (Toni, 2026-11-22: "Fill-only
/// tool").
enum LoginsCapability {
    @MainActor static func make(store: SignInStore = .shared, own: OwnPages = BrowserCapability.ownPages) -> Capability
    {
        Capability(
            id: CapabilityRegistry.logins, title: "Sign-in",
            summary: "Sign in to sites with your passwords from Passwords", readTools: [find(store: store)],
            writeTools: [fill(store: store, own: own)], levels: [.off, .readWrite], onTitle: "On")
    }

    static let noneYet =
        "Latchkey holds no sign-ins yet. The Mac's owner can hand them over from Latchkey's menu: Export Passwords to Latchkey…"
    static let unreadable =
        "Latchkey can't read its sign-ins right now (the Mac may not have been unlocked since it started). Try again later."

    static func find(store: SignInStore) -> ToolEntry {
        ToolEntry(
            tool: .make(
                "logins_find", title: "Find Saved Sign-ins",
                description: """
                    Lists the sites Latchkey can sign in to with the owner's passwords from Apple's Passwords app: \
                    each site, the user name, and whether Latchkey also has its verification code. Never shows a \
                    password or a code. With site: only sign-ins for that site. To type one into a page of \
                    Claude's, use logins_fill.
                    """,
                input: ["site": .stringParam("Only sign-ins for this site, like github.com")], readOnly: true),
            handler: { args in
                let logins: [SavedSignIn]
                let imported: Date
                switch store.load() {
                case .none: return .text(noneYet)
                case .unreadable: return .text(unreadable, isError: true)
                case .some(let c):
                    guard !c.logins.isEmpty else { return .text(noneYet) }
                    logins = c.logins
                    imported = c.imported
                }
                let wanted = args["site"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let key = wanted.isEmpty ? nil : (SiteMatch.site(of: wanted) ?? wanted)
                let shown = logins.filter { l in
                    guard let key else { return true }
                    return l.site.contains(key) || key.hasSuffix("." + l.site) || key == l.site
                }
                .sorted { ($0.site, $0.user) < ($1.site, $1.user) }
                let when = imported.formatted(date: .abbreviated, time: .shortened)
                guard !shown.isEmpty else {
                    return .text(
                        "No saved sign-in for \(wanted). Latchkey holds \(logins.count) from Passwords (taken in \(when))."
                    )
                }
                // Totals first, codes said either way (fb_BCMYNJQJP20GB7EQ92NTA2R9M0, 2026-11-21: with no
                // marker at all, "none has a code" read like a missing marker).
                let sites = Set(shown.map(\.site)).count
                let codes = shown.filter { $0.otp != nil }.count
                var out =
                    "Saved sign-ins (from the owner's Passwords, taken in \(when)); type one into a page with logins_fill.\n"
                    + "\(shown.count) sign-in\(shown.count == 1 ? "" : "s") for \(sites) site\(sites == 1 ? "" : "s"); "
                    + (codes == 0
                        ? "none has a verification code in Passwords.\n"
                        : "\(codes) with a verification code, marked below; the rest have none.\n")
                var left = 0
                for l in shown {
                    let line =
                        "- \(l.site) — \(l.user.isEmpty ? "(no user name)" : l.user)"
                        + (l.otp != nil ? " (has a verification code)" : "") + "\n"
                    if out.count + line.count > ResultLimit.characters - 100 {
                        left += 1
                        continue
                    }
                    out += line
                }
                if left > 0 { out += "\(left) more didn't fit: pass site to narrow the list." }
                return .text(out)
            })
    }

    /// `finder` and `cleanup`: the shared ones unless a test gives its own.
    static func fill(
        store: SignInStore, own: OwnPages, finder: CodeFinder? = nil, cleanup: PendingCleanup? = nil
    ) -> ToolEntry {
        ToolEntry(
            tool: .make(
                "logins_fill", title: "Type a Saved Sign-in",
                description: """
                    Types the owner's saved user name, password, or a verification code into a field of one of \
                    Claude's own pages (opened with browser_read; name it with page, like p4k2), then presses the \
                    button you name. Claude never sees the password or a code from Passwords. You do the signing in: read \
                    the page, name the field by its reference from browser_read (field, like e18), say what to \
                    type (fill: user, password, or code) and, for a password or a code, the button to press right \
                    after (press, like e21: Sign On, Continue). Latchkey types it as a keyboard does, presses that \
                    button, empties what it typed, and answers with the page as it is; read the page after each \
                    fill and judge for yourself whether you are signed in, asked for a code, refused, or stopped \
                    by a check. It never presses anything else: press buttons like "Text me" yourself with \
                    browser_act. A code: Latchkey types the sign-in's code from Passwords when it has one. A code \
                    the site texted or emailed can be typed three ways (being compared; any works): (1) read it \
                    yourself and pass it as code: a texted code with messages_find and messages_read (wait and \
                    look again as long as you like), then delete that text with messages_delete; an emailed one \
                    with your own email tool, else mail_find and mail_read, then archive that email \
                    (mail_archive). (2) code_from text or email: Latchkey finds the newest code for this site \
                    that came since it typed the password, types it without showing it to you, and deletes the \
                    text or archives the email; if none has come yet, it says so: wait as long as you like and \
                    call again. (3) code with check_code true: Latchkey types your code only if a text or email \
                    for this site since the password holds it, then deletes or archives that message. user: which user name, when Latchkey holds several (logins_find lists \
                    them). Works in Latchkey's own browser and in Claude's Safari tabs, never in the owner's own \
                    tabs. Some sites' protection against bots turns away Latchkey's own background browser but \
                    lets Safari through (the site ends the sign-in, shows a check, or says nothing works): while \
                    the Mac is unlocked, move the page into a background Safari tab with browser_read \
                    sign_in_again and sign in there; while it is locked, tell the owner the site needs the Mac \
                    unlocked.
                    """,
                input: [
                    "page": .stringParam("Claude's page, by the name browser_read gave, like p4k2"),
                    "field": .stringParam("The field to type into, by its reference from browser_read, like e18"),
                    "fill": .enumParam(
                        ["user", "password", "code"], "What to type: the saved user name, password, or a code"),
                    "press": .stringParam(
                        "The button to press right after, like e21 (needed with password and code)"),
                    "user": .stringParam("Which saved user name, when there are several"),
                    "code": .stringParam(
                        "A verification code you read in the owner's texts or email, for fill code (else the one from Passwords)"
                    ),
                    "code_from": .enumParam(
                        ["text", "email"],
                        "For fill code: Latchkey finds the site's newest code in the owner's texts or email and types it, unseen"
                    ),
                    "check_code": .boolParam(
                        "With code: type it only if a recent text or email for this site holds it"),
                ], required: ["field", "fill"], readOnly: false, destructive: false, openWorld: true,
                deadlineMS: 30_000),
            handler: { args in
                await BrowserCapability.run {
                    let (f, c) = await MainActor.run { (finder ?? CodeFinder.shared, cleanup ?? PendingCleanup.shared) }
                    return try await fill(args, store: store, own: own, finder: f, cleanup: c)
                }
            })
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private enum Target {
        case own(LockedBrowser)
        case safari(String, SafariBrowser)
    }

    private static func fill(
        _ args: JSONValue, store: SignInStore, own: OwnPages, finder: CodeFinder, cleanup: PendingCleanup
    ) async throws -> ToolResult {
        func arg(_ k: String) -> String { args[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let name = arg("page").isEmpty ? nil : arg("page")
        let field = arg("field"), kind = arg("fill"), press = arg("press"), wantedUser = arg("user")
        let givenCode = arg("code"), codeFrom = arg("code_from")
        let checkCode = args["check_code"]?.boolValue ?? false
        guard !field.isEmpty else { return .text("Name the field to type into with field, like e18.", isError: true) }
        guard ["user", "password", "code"].contains(kind) else {
            return .text("fill must be user, password, or code.", isError: true)
        }
        // FR-1376: the codes experiment's three ways, one at a time.
        if !codeFrom.isEmpty {
            guard ["text", "email"].contains(codeFrom) else {
                return .text("code_from must be text or email.", isError: true)
            }
            guard kind == "code", givenCode.isEmpty, !checkCode else {
                return .text("code_from goes with fill code alone, without code or check_code.", isError: true)
            }
        }
        if checkCode, givenCode.isEmpty || kind != "code" {
            return .text("check_code goes with fill code and the code you pass as code.", isError: true)
        }
        if kind != "user", press.isEmpty {
            return .text(
                "With \(kind), name the button to press right after with press (like Sign On or Continue): a \(kind) never stays typed in the page.",
                isError: true)
        }
        // FR-1364: a code Claude read in the owner's email with its own tool.
        if !givenCode.isEmpty, givenCode.range(of: #"^[A-Za-z0-9-]{4,10}$"#, options: .regularExpression) == nil {
            return .text("code must be the verification code alone: 4 to 10 letters or digits.", isError: true)
        }
        let target: Target = try await MainActor.run {
            if let s = own.safariCalled(name) { return .safari(s.name, s.browser) }
            return .own(try own.page(name))
        }
        let run: (String) async throws -> (detail: String, page: PageScripts.Page, address: String)
        let click: (String) async throws -> PageScripts.Page
        switch target {
        case .own(let l):
            run = { try await l.signInScript($0, navigates: false) }
            click = { try await l.click($0) }
        case .safari(_, let s):
            run = { try await s.signInScript($0, navigates: false) }
            click = { try await s.click($0) }
        }
        var secret = ""
        func answer(_ said: String, _ shown: PageScripts.Page, isError: Bool = false) async -> ToolResult {
            let page = PageScripts.redacted(shown, secret)
            var r: ToolResult
            switch target {
            case .own(let l): r = await BrowserCapability.told(.text(said + "\n\n" + PageScripts.answer(page)), l)
            case .safari(let n, let s): r = await BrowserCapability.safariAnswer(page, n, s, note: said + "\n\n")
            }
            r.isError = isError
            return r
        }
        let logins: [SavedSignIn]
        switch store.load() {
        case .none: return .text(noneYet, isError: true)
        case .unreadable: return .text(unreadable, isError: true)
        case .some(let c): logins = c.logins
        }
        // The page's address as the browser has it: a page's script can't make itself another site.
        let here0 = try await run(PageScripts.signInHere)
        let address = here0.address
        let host = BrowserCapability.host(address)
        guard address.lowercased().hasPrefix("https:") else {
            return .text(
                "Latchkey types sign-ins only on https pages; this page is \(address.prefix(200)).", isError: true)
        }
        // The sign-in saved for this very page first, then one for a site it is under, then one
        // elsewhere on the same registered site.
        let pageHost = host.lowercased()
        func near(_ l: SavedSignIn) -> Int { l.site == pageHost ? 0 : pageHost.hasSuffix("." + l.site) ? 1 : 2 }
        let here = logins.filter { SiteMatch.fills(site: $0.site, on: address) }.sorted { near($0) < near($1) }
        guard !here.isEmpty else {
            let sites = Array(Set(logins.map(\.site))).sorted()
            return .text(
                "Latchkey holds no saved sign-in for \(host) (this page). "
                    + (sites.isEmpty
                        ? ""
                        : "It holds sign-ins for: \(sites.prefix(20).joined(separator: ", "))\(sites.count > 20 ? ", …" : "") (logins_find lists them all)."),
                isError: true)
        }
        var chosen = here
        if !wantedUser.isEmpty {
            chosen = here.filter { $0.user.caseInsensitiveCompare(wantedUser) == .orderedSame }
            guard !chosen.isEmpty else {
                return .text(
                    "\(host) has no saved sign-in for \(wantedUser). Its user names: \(users(here)).", isError: true)
            }
        }
        // A code Claude passes is Claude's own: no saved sign-in needs choosing (feedback
        // fb_CSBD7DB4HB727KS0GZ646SQ8PM, 2026-11-22: GitHub's seven sign-ins asked for one).
        if Set(chosen.map { $0.user.lowercased() }).count > 1,
            !(kind == "code" && (!givenCode.isEmpty || !codeFrom.isEmpty))
        {
            return .text("\(host) has several saved sign-ins: \(users(chosen)). Call again with user.", isError: true)
        }
        let login = chosen[0]
        // FR-1321, FR-1328: only on the saved site, by the browser's own address, checked again in
        // the page just before typing.
        guard let fillHost = PageScripts.fillHost(login, address: address) else {
            return .text("Latchkey types \(login.site)'s sign-in only on \(login.site)'s own pages.", isError: true)
        }
        let who = login.user.isEmpty ? "" : " (\(login.user))"

        // What to type.
        var value = ""
        var fromPasswords = false
        // Counted as used only once typed: a field that refused it leaves it for the next call.
        var usedStep: UInt64?
        // The text or email Latchkey found the code in (ways 2 and 3): counted as used, and
        // deleted or archived, once the code is typed and sent.
        var foundIn: String?
        switch kind {
        case "user":
            guard !login.user.isEmpty else { return .text("\(host)'s saved sign-in has no user name.", isError: true) }
            value = login.user
        case "password":
            value = login.password
        default:
            if !codeFrom.isEmpty {
                // Way 2: Latchkey finds the code; Claude never sees it.
                let email = codeFrom == "email"
                guard await finder.readable(email: email) else {
                    return .text(
                        email
                            ? "Latchkey can't read the owner's email: Mail is Off in Latchkey's settings. Nothing was typed."
                            : "Latchkey can't read the owner's texts: Messages is Off in Latchkey's settings. Nothing was typed.",
                        isError: true)
                }
                let since = await finder.since(login.site)
                guard let found = await finder.find(site: login.site, email: email, since: since) else {
                    let ago = Int(Date().timeIntervalSince(since))
                    return await answer(
                        "No \(email ? "email" : "text") with a code for \(login.site) has come since \(clock(since)) (\(ago) seconds ago), so nothing was typed. If the site said it sent one, wait as long as you like and call again.",
                        here0.page)
                }
                value = found.code
                foundIn = found.id
            } else if !givenCode.isEmpty {
                if checkCode {
                    // Way 3: Claude's code, typed only when a message for this site holds it.
                    let since = await finder.since(login.site)
                    guard let id = await finder.holding(givenCode, site: login.site, since: since) else {
                        return await answer(
                            "No text or email for \(login.site) since \(clock(since)) holds that code, so nothing was typed. Pass the code from the newest message, or call without check_code.",
                            here0.page, isError: true)
                    }
                    foundIn = id
                }
                value = givenCode
            } else if let totp = login.otp.flatMap({ TOTP(uri: $0) }) {
                // FR-1324's rule that stays: each 30-second code is typed once.
                let at = Date()
                let step = totp.step(at: at)
                guard store.mayUseCode(login, step: step) else {
                    let left =
                        Int(
                            Double(totp.period)
                                - at.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(totp.period))) + 1
                    return await answer(
                        "This code from Passwords was already typed; the next one comes in \(left) seconds: call again then.",
                        here0.page)
                }
                value = totp.code(at: at)
                usedStep = step
                fromPasswords = true
            } else {
                // Toni, 2026-11-22: "The agent reads the messages, archives them etc".
                return await answer(
                    "Latchkey holds no code generator for \(login.site) in Passwords, so nothing was typed. Read the code yourself (a text with messages_find and messages_read, an email with your own email tool or mail_find and mail_read), then call again with code.",
                    here0.page, isError: true)
            }
        }

        if kind != "user" { secret = value }
        // Type, then press, then empty what was typed (FR-1311), whatever happened in between.
        struct Step: Decodable {
            var step: String
            var boxes: Int?
            var `is`: String?
        }
        let typed: Step
        do {
            let r = try await run(PageScripts.fillField(ref: field, kind: kind, value: value, host: fillHost))
            typed = (try? JSONDecoder().decode(Step.self, from: Data(r.detail.utf8))) ?? Step(step: "unheld")
        } catch SafariBrowser.Failure.elementMissing {
            return .text(
                "There's no \(field) on the page now (it may have changed). Read it again with browser_read.",
                isError: true)
        }
        func clear() async -> PageScripts.Page? { try? await run(PageScripts.clearSignIn).page }
        switch typed.step {
        case "filled": break
        case "wrongsite":
            return .text(
                "The page went to another site before Latchkey typed anything, so nothing was typed.", isError: true)
        case "notfield":
            let what = typed.is ?? "another kind of"
            let wanted =
                kind == "password"
                ? "a password field" : kind == "user" ? "a text or email field" : "a code field or box"
            let page = await clear() ?? here0.page
            let said =
                what == "password" && kind == "user"
                ? "\(field) is a password field: Latchkey types the user name only into a text, email, or phone field."
                : "\(field) isn't \(wanted) (it is a \(what) field)."
            return await answer(said + " Nothing was typed or pressed.", page, isError: true)
        default:
            let page = await clear() ?? here0.page
            return await answer(
                "\(field) didn't hold what Latchkey typed (the page changed it), so nothing was pressed and the field was emptied.",
                page, isError: true)
        }
        if let usedStep { store.usedCode(login, step: usedStep) }
        // Ways 2 and 3 look for codes that came after the password Latchkey typed here.
        if kind == "password" { await finder.passwordTyped(login.site) }
        var page = here0.page
        var pressed = ""
        if !press.isEmpty {
            do {
                page = try await click(press)
                pressed = ", then pressed \(press)"
            } catch {
                page = await clear() ?? page
                let why = (error as? SafariBrowser.Failure).map(BrowserCapability.explain) ?? "\(error)"
                return await answer(
                    "Typed into \(field), but pressing \(press) didn't work: \(why) The field was emptied.", page,
                    isError: true)
            }
        }
        if kind != "user", let cleared = await clear() { page = cleared }

        // The message the code came in is never taken again, and is deleted or archived now
        // (or at the next unlock), while Messages or Mail is Read & write.
        var cleaned = ""
        if let foundIn {
            await finder.markUsed(foundIn)
            let email = MailCodes.Place(key: foundIn) != nil
            let it = email ? "the email it came in" : "the text it came in"
            if await MainActor.run(body: { cleanup.mayDo(foundIn) }) {
                // Within 12 s, so the answer beats the tool's 30 s (Constitution II); a slower
                // cleanup goes on by itself and is in the activity log.
                let job = Task { await cleanup.request(foundIn) }
                switch await Deadline.first(within: .seconds(12), { await job.value }) {
                case nil: cleaned = " Latchkey is still \(email ? "archiving" : "deleting") \(it)."
                case .done: cleaned = " Latchkey \(email ? "archived" : "deleted") \(it)."
                case .atUnlock:
                    cleaned = " Latchkey will \(email ? "archive" : "delete") \(it) when the Mac is next unlocked."
                case .failed(let why): cleaned = " Latchkey couldn't \(email ? "archive" : "delete") \(it): \(why)"
                }
            } else {
                cleaned = " \(email ? "Mail" : "Messages") isn't Read & write in Latchkey's settings, so \(it) stays."
            }
        }

        // What was typed.
        var said: String
        var activity: String
        let boxes = (typed.boxes ?? 0) > 1 ? " (\(typed.boxes!) boxes)" : ""
        switch kind {
        case "user", "password":
            let what = kind == "user" ? "user name" : "password"
            said = "Typed the saved \(what) for \(login.site)\(who) into \(field)\(pressed)."
            activity = "Typed the saved \(what) for \(login.site)\(who)\(pressed)"
        default:
            let from =
                fromPasswords
                ? "the code from Passwords"
                : !codeFrom.isEmpty
                    ? "the code from the owner's \(codeFrom == "email" ? "email" : "texts")"
                    : checkCode ? "the code you passed (a message for \(login.site) holds it)" : "the code you passed"
            said = "Typed \(from) into \(field)\(boxes)\(pressed)." + cleaned
            if !fromPasswords, foundIn == nil {
                said += " If it came by text or email, delete that text (messages_delete) or archive that email now."
            }
            activity = "Typed \(from) for \(login.site)\(who)\(pressed)"
        }
        // FR-1327: every fill in the activity log, never the secret; the user name stays out of
        // macOS's own log.
        let browser = if case .own = target { "Latchkey's own browser" } else { "a Safari tab of Claude's" }
        EventLog.shared.record(.browser, "Sign-in on \(host) in \(browser): \(activity)", systemLog: false)
        var r = await answer(said, page)
        r.activity = activity
        return r
    }

    private static func users(_ logins: [SavedSignIn]) -> String {
        logins.map { $0.user.isEmpty ? "(no user name)" : $0.user }.joined(separator: ", ")
    }
}
