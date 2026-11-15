import Foundation

/// The Browser tools Claude sees: read and act (consolidated 2026-10-23).
extension BrowserCapability {
    /// Runs one call with what it asked for (FR-445, FR-447): the page it names, and whether it
    /// names one of the owner's tabs, which it picks first.
    static func asked(
        _ args: JSONValue, _ ops: Operations, browser: SafariBrowser, _ body: @escaping @Sendable () async -> ToolResult
    ) async -> ToolResult {
        let page: String?
        switch args["page"] {
        case nil, .null?: page = nil
        case .string(let s)?: page = s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        default: return .text("page is the name of one of Claude's pages, like \"p4k2\".", isError: true)
        }
        let tab = args["tab"].flatMap { $0.isPresent ? $0 : nil }
        return await Asked.$page.withValue(page) {
            await Asked.$tab.withValue(tab != nil) {
                if let tab {
                    let picked = await ops.call("browser_tabs", .object(["select": tab]))
                    if picked.isError { return picked }
                }
                return await body()
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
                        Opens and reads web pages on the Mac. Claude's own pages are in Latchkey's own browser \
                        (not Safari, so nothing changes in the owner's Safari window), signed in with a copy of \
                        the owner's Safari sign-ins, taken again with each url opened. With url: opens that page \
                        in a new page of Claude's own and answers with its name, like p4k2; with url and page, \
                        opens it in that page. Pass page on every later call (other chats may have pages open \
                        too; with several open, a call without page is refused with the list). tabs: lists every \
                        tab of every Safari window of the owner's, each with a reference like 4213.2 (window, \
                        then tab), and Claude's own pages. With tab: reads that tab of the owner's, in the \
                        background (name it on each call that should use it). With back: goes back. With \
                        nothing else: reads the page. Answers with the page's text and the links, buttons, and \
                        fields on it, each with a reference like e12 for browser_act. Long pages come in parts; \
                        pass offset to read on. screenshot: shows the page as an image. sign_in_again: when a \
                        page of Claude's comes back signed out after a click or typing, takes Safari's cookies \
                        again and loads the page again. A page's confirm or prompt that Claude didn't answer in \
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
                            "Take Safari's cookies again and load Claude's page again (it came back signed out)"),
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
                        return await asked(rest, ops, browser: browser) { await ops.call("browser_open", rest) }
                    }
                    if args["tabs"] == .bool(true), args["tab"]?.isPresent != true {
                        return await ops.call("browser_tabs", .object([:]))
                    }
                    return await asked(args, ops, browser: browser) {
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
                        for files_read), script (code: JavaScript run in the page; its result is returned), \
                        dialog (answers the dialog Claude's page waits on: confirm true for OK or false for \
                        Cancel, prompt_text for a prompt), close (closes the page or the owner's tab). Keys and \
                        hover are a script's, not a real keyboard's or mouse's: most pages take them; one that \
                        doesn't needs computer control. The page's own dialogs: an alert is dismissed and told; \
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
                    return await asked(args, ops, browser: browser) {
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
