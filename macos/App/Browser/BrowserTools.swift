import Foundation

/// The Browser tools Claude sees: read and act (consolidated 2026-10-23).
extension BrowserCapability {
    static func readTools(browser: SafariBrowser, locked: @escaping LockedRoute = noLocked) -> [ToolEntry] {
        let ops = Operations(readOperations(browser: browser, locked: locked))
        return [
            ToolEntry(
                tool: .make(
                    "browser_read", title: "Read the Web",
                    description: """
                        Uses Safari on the Mac, signed in as the Mac's owner. Claude opens pages in a page of its \
                        own (a tab behind the owner's tab, or a window of Claude's own, as the owner chose), and \
                        can also work in any of the owner's tabs and windows, in the background. tabs: lists every \
                        tab of every Safari window, each with a reference like 4213.2 (window, then tab), and which \
                        is in front. With tab: Claude works in that tab from then on (reads it, and browser_act acts \
                        in it) until it opens a url or picks another tab. With url: opens that page in Claude's own \
                        page (new_tab for a new tab, in a window of Claude's own only). With back: goes back. With \
                        nothing: reads the page Claude works in. Answers with the page's text and the links, \
                        buttons, and fields on it, each with a reference like e12 for browser_act. Long pages come \
                        in parts; pass offset to read on. screenshot: shows the page as an image. While the Mac is \
                        locked, Safari doesn't answer, so Latchkey uses a browser of its own instead, signed in \
                        with the owner's Safari cookies, for the pages Claude opens: one page, its own history \
                        (the owner's tabs are still tried through Safari); it is closed when the Mac is unlocked, \
                        and Safari is used again.
                        """,
                    input: [
                        "url": .stringParam("A page to open"),
                        "new_tab": .boolParam("With url: open it in a new tab (in a window of Claude's own)"),
                        "back": .boolParam("Go back to the previous page"),
                        "tab": .stringParam("Work in this tab: its reference from the tab list, like 4213.2"),
                        "tabs": .boolParam("List every tab of every Safari window"),
                        "screenshot": .boolParam("Show the page as an image"),
                        "offset": .integerParam("Read the page from this character"),
                    ], readOnly: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    if args.hasAny("url") { return await ops.call("browser_open", args) }
                    if args["back"] == .bool(true) { return await ops.call("browser_back", args) }
                    if args["screenshot"] == .bool(true) { return await ops.call("browser_screenshot", args) }
                    if let tab = args["tab"], tab.isPresent {
                        let switched = await ops.call("browser_tabs", .object(["select": tab]))
                        if switched.isError { return switched }
                        return await ops.call("browser_read", .object([:]))
                    }
                    if args["tabs"] == .bool(true) { return await ops.call("browser_tabs", .object([:])) }
                    return await ops.call("browser_read", args)
                })
        ]
    }

    static let actions = [
        "click", "type", "select", "key", "hover", "scroll", "upload", "download", "script", "close",
    ]

    static func writeTools(browser: SafariBrowser, locked: @escaping LockedRoute = noLocked) -> [ToolEntry] {
        // browser_act's tab picks the tab first, through the tab list's own operation.
        let ops = Operations(
            writeOperations(browser: browser, locked: locked)
                + readOperations(browser: browser, locked: locked).filter { $0.tool.name == "browser_tabs" })
        return [
            ToolEntry(
                tool: .make(
                    "browser_act", title: "Act on the Page",
                    description: """
                        Acts on the page Claude works in, in Safari, in the background, then answers with the page: \
                        Claude's own page, or the owner's tab picked with browser_read and tab (or with tab here). \
                        action: click (ref: a link or button), type (ref: a field, text; or a list and the \
                        option's text; submit sends the form), select (ref: a list, options: the texts to choose, \
                        several in a list that takes several), key (keys: like "Enter", "Tab Tab", "Escape", \
                        "ArrowDown", "cmd+a", pressed in ref or the focused field), hover (ref), scroll \
                        (direction: down, up, left, right, top, bottom; amount in pixels; ref to scroll inside an \
                        element), upload (ref: a file field or drop place, paths: files on the Mac), download \
                        (ref: a link, or url, or neither for the page itself, e.g. a PDF: saved to the Mac's \
                        Downloads folder, and the answer names the path for files_read), script (code: \
                        JavaScript run in the page; its result is returned), close (closes the tab Claude works \
                        in, the owner's included). Keys and hover are a script's, not a real keyboard's or \
                        mouse's: most pages take them; one that doesn't needs computer control. The \
                        page's own dialogs never wait: an alert is dismissed, a confirm gets Cancel unless confirm \
                        is true, a prompt gets prompt_text or nothing, and the answer says what each one said.
                        """,
                    input: [
                        "action": .enumParam(actions, "What to do"),
                        "tab": .stringParam("First work in this tab: its reference from the tab list, like 4213.2"),
                        "ref": .stringParam("The element's reference from browser_read, like e12"),
                        "text": .stringParam("For type: the text, or the option to choose"),
                        "submit": .boolParam("For type: send the form afterwards"),
                        "code": .stringParam("For script: the JavaScript"),
                        "confirm": .boolParam("Answer OK to a confirm dialog this action brings up (default Cancel)"),
                        "prompt_text": .stringParam("The text for a prompt dialog this action brings up"),
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
                    if let tab = args["tab"], tab.isPresent {
                        let picked = await ops.call("browser_tabs", .object(["select": tab]))
                        if picked.isError { return picked }
                    }
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
                    case "close": return await ops.call("browser_close", args)
                    default: return .unknown("action", action, allowed: actions)
                    }
                })
        ]
    }
}
