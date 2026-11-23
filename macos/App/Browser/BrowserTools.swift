import Foundation

/// The Browser tools Claude sees: read and act (consolidated 2026-10-23).
extension BrowserCapability {
    /// Runs one call with what it asked for (FR-445, FR-447): the page it names, and whether it
    /// names one of the owner's tabs, which it picks first.
    static func asked(
        _ args: JSONValue, _ ops: Operations, browser: SafariBrowser, own: OwnPages, opening: Bool = false,
        _ body: @escaping @Sendable () async -> ToolResult
    ) async -> ToolResult {
        let page: String?
        switch args["page"] {
        case nil, .null?: page = nil
        case .string(let s)?: page = s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        default: return .text("page is the name of one of Claude's pages, like \"p4k2\".", isError: true)
        }
        let tab = args["tab"].flatMap { $0.isPresent ? $0 : nil }
        // FR-458: copies taken while the Mac was locked go once it is unlocked.
        await own.forgetCopiesIfUnlocked()
        // FR-455: a page of Claude's that is a Safari tab of Claude's is worked in through its own
        // driver (not when the call names one of the owner's tabs).
        // A url without page opens a new page: never the only page open, which may be another
        // chat's (a Procare sync's url loaded into a claude.ai page of another chat, 2026-11-22).
        let safari = tab == nil && !(opening && page == nil) ? await own.safariCalled(page) : nil
        return await Asked.$page.withValue(page) {
            await Asked.$tab.withValue(tab != nil) {
                await Asked.$safari.withValue(safari?.browser) {
                    await Asked.$safariName.withValue(safari?.name) {
                        guard let tab else { return await body() }
                        // The pick and the action are one turn: another chat's pick can't come
                        // in between (a click meant for one tab landed in another chat's tab,
                        // 2026-11-19). Waited for at most 5 s, so the action still ends well
                        // within the tool's 30 s (review: never after Claude was told it failed).
                        guard await browser.turns.enter(within: .seconds(5)) else {
                            return .text(
                                "Another chat is working in the owner's Safari tabs right now, so nothing was done. Call again in a moment.",
                                isError: true)
                        }
                        let picked = await ops.call("browser_tabs", .object(["select": tab]))
                        let r = picked.isError ? picked : await body()
                        await browser.turns.leave()
                        return r
                    }
                }
            }
        }
    }

    static func readTools(browser: SafariBrowser, own: OwnPages) -> [ToolEntry] {
        let ops = Operations(readOperations(browser: browser, own: own))
        return [
            ToolEntry(
                tool: .make(
                    "browser_read", title: "Read the Web",
                    description: """
                        Opens and reads web pages on the Mac. Claude's own pages: while the Mac is unlocked, a \
                        site the owner is signed in to in Safari opens in a background Safari tab of Claude's \
                        (the owner's real sign-in; the owner's front tab stays in front), and any other site in \
                        Latchkey's own browser without the owner's sign-ins; while the Mac is locked, every page \
                        is in Latchkey's own browser with a copy of Safari's sign-ins (a site may then sign the \
                        owner out in Safari). Each answer says which. With url: opens that page in a new page of \
                        Claude's own and answers with its name, like p4k2; with url and page, opens it in that \
                        page. Pass page on every later call (other chats may have pages open \
                        too; with several open, a call without page is refused with the list). tabs: lists every \
                        tab of every Safari window of the owner's, each with a reference like 4213.2 (window, \
                        then tab), and Claude's own pages. With tab: reads that tab of the owner's, in the \
                        background (name it on each call that should use it). With back: goes back. With \
                        nothing else: reads the page. Answers with the page's text and the links, buttons, and \
                        fields on it, each with a reference like e12 for browser_act. Long pages come in parts; \
                        pass offset to read on. screenshot: shows the page as an image. sign_in_again: when a \
                        page of Claude's in Latchkey's own browser is signed out but needs the owner's sign-in: \
                        while the Mac is unlocked, moves it into a Safari tab of Claude's at the same address; \
                        while locked, takes Safari's cookies again and loads the page again. A page's confirm or prompt that Claude didn't answer in \
                        advance waits for Claude: the answer says what it asks, and browser_act action dialog \
                        answers it. A page that is a file (a PDF) isn't shown: save it with browser_act \
                        download.
                        """,
                    input: [
                        "url": .stringParam("A page to open"),
                        "page": .stringParam("Claude's page to use, by the name an earlier answer gave, like p4k2"),
                        "back": .boolParam("Go back to the previous page"),
                        "tab": .stringParam(
                            "Use this tab of the owner's: its reference from the tab list, like 4213.2"),
                        "tabs": .boolParam("List every tab of every Safari window, and Claude's own pages"),
                        "screenshot": .boolParam("Show the page as an image"),
                        "sign_in_again": .boolParam(
                            "Claude's page is signed out but needs the owner's sign-in: move it into Safari (unlocked) or take Safari's cookies again (locked)"
                        ),
                        "offset": .integerParam("Read the page from this character"),
                    ], readOnly: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    // With a url, Claude's own page opens: a tab named with it isn't used.
                    if args.hasAny("url") {
                        let rest: JSONValue
                        if case .object(var o) = args {
                            o["tab"] = nil
                            rest = .object(o)
                        } else {
                            rest = args
                        }
                        return await asked(rest, ops, browser: browser, own: own, opening: true) {
                            let named = BrowserCapability.OpenedName()
                            let opened = await BrowserCapability.Asked.$opened.withValue(named) {
                                await ops.call("browser_open", rest)
                            }
                            // screenshot with url: the new page's picture too (2026-11-22: only
                            // its text came back).
                            guard args["screenshot"] == .bool(true), !opened.isError, let name = named.name
                            else { return opened }
                            var shot = rest
                            if case .object(var o) = shot {
                                o["page"] = .string(name)
                                o["url"] = nil
                                shot = .object(o)
                            }
                            let picture = await asked(shot, ops, browser: browser, own: own) {
                                await ops.call("browser_screenshot", shot)
                            }
                            return picture.isError ? opened : picture
                        }
                    }
                    if args["tabs"] == .bool(true), args["tab"]?.isPresent != true {
                        return await ops.call("browser_tabs", .object([:]))
                    }
                    return await asked(args, ops, browser: browser, own: own) {
                        if args["back"] == .bool(true) { return await ops.call("browser_back", args) }
                        if args["screenshot"] == .bool(true) { return await ops.call("browser_screenshot", args) }
                        if args["sign_in_again"] == .bool(true) {
                            return await ops.call("browser_sign_in_again", args)
                        }
                        return await ops.call("browser_read", args)
                    }
                })
        ]
    }

    static let actions = [
        "click", "type", "select", "key", "hover", "scroll", "upload", "download", "script", "dialog", "close",
    ]

    static func writeTools(browser: SafariBrowser, own: OwnPages) -> [ToolEntry] {
        // browser_act's tab picks the tab first, through the tab list's own operation.
        let ops = Operations(
            writeOperations(browser: browser, own: own)
                + readOperations(browser: browser, own: own).filter { $0.tool.name == "browser_tabs" })
        return [
            ToolEntry(
                tool: .make(
                    "browser_act", title: "Act on the Page",
                    description: """
                        Acts on a page, in the background, then answers with the page: Claude's own page (name \
                        it with page, like p4k2, as browser_read gave it), or a tab of the owner's Safari (name \
                        it with tab on each call, like 4213.2). action: click (ref: a link or button), type \
                        (ref: a field, text; or a list and the option's text; submit sends the form), select \
                        (ref: a list, options: the texts to choose, several in a list that takes several), key \
                        (keys: like "Enter", "Tab Tab", "Escape", "ArrowDown", "cmd+a", pressed in ref or the \
                        focused field), hover (ref), scroll (direction: down, up, left, right, top, bottom; \
                        amount in pixels; ref to scroll inside an element), upload (ref: a file field or drop \
                        place, paths: files on the Mac), download (ref: a link, or url, or neither for the page \
                        itself, e.g. a PDF: saved to the Mac's Downloads folder, and the answer names the path \
                        for files_read), script (code: JavaScript run in the page; its result is returned, or the error the page gave; await works, and it runs also where the page forbids eval), \
                        dialog (answers the dialog Claude's page waits on: confirm true for OK or false for \
                        Cancel, prompt_text for a prompt), close (closes the page or the owner's tab). Clicks, keys, \
                        and hover are a script's, not a real mouse's or keyboard's: a click presses down and up \
                        at the element's centre, then clicks. Most pages take them. When the answer says the \
                        page didn't change, try key Enter or Space in the element, or a script that sends the \
                        events the page listens for; computer control is the last way, and only while the Mac \
                        is unlocked. The page's own dialogs: an alert is dismissed and told; \
                        confirm and prompt_text answer a dialog the action brings up in advance (in Claude's \
                        page also one that comes up to 5 seconds later); otherwise, in Claude's page a confirm \
                        or prompt waits for Claude's answer (action dialog; Cancel after 5 minutes), and in the \
                        owner's tabs it gets Cancel.
                        """,
                    input: [
                        "action": .enumParam(actions, "What to do"),
                        "page": .stringParam("Claude's page, by the name browser_read gave, like p4k2"),
                        "tab": .stringParam(
                            "A tab of the owner's instead: its reference from the tab list, like 4213.2"),
                        "ref": .stringParam("The element's reference from browser_read, like e12"),
                        "text": .stringParam("For type: the text, or the option to choose"),
                        "submit": .boolParam("For type: send the form afterwards"),
                        "code": .stringParam("For script: the JavaScript"),
                        "confirm": .boolParam(
                            "OK (true) or Cancel (false) to a confirm dialog: for dialog, or in advance for this action"
                        ),
                        "prompt_text": .stringParam(
                            "The text for a prompt dialog: for dialog, or in advance for this action"),
                        "options": listParam("For select: the options' texts or values"),
                        "keys": listParam("For key: keys like Enter, Tab, Escape, ArrowDown, cmd+a"),
                        "direction": .enumParam(directions, "For scroll: which way (default down)"),
                        "amount": .integerParam("For scroll: pixels (default most of what shows)"),
                        "paths": listParam("For upload: the files' paths on the Mac"),
                        "url": .stringParam("For download: an address to save instead of a link"),
                    ], required: ["action"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    let action = args["action"]?.stringValue
                    guard actions.contains(action ?? "") else { return .unknown("action", action, allowed: actions) }
                    return await asked(args, ops, browser: browser, own: own) {
                        switch action {
                        case "click": return await ops.call("browser_click", args)
                        case "type": return await ops.call("browser_type", args)
                        case "script": return await ops.call("browser_script", args)
                        case "select": return await ops.call("browser_select", args)
                        case "key": return await ops.call("browser_key", args)
                        case "hover": return await ops.call("browser_hover", args)
                        case "scroll": return await ops.call("browser_scroll", args)
                        case "upload": return await ops.call("browser_upload", args)
                        case "download": return await ops.call("browser_download", args)
                        case "dialog": return await ops.call("browser_dialog", args)
                        case "close": return await ops.call("browser_close", args)
                        default: return .unknown("action", action, allowed: actions)
                        }
                    }
                })
        ]
    }
}
