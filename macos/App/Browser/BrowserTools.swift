import Foundation

/// The Browser tools Claude sees: read and act (consolidated 2026-10-23).
extension BrowserCapability {
    static func readTools(browser: SafariBrowser) -> [ToolEntry] {
        let ops = Operations(readOperations(browser: browser))
        return [
            ToolEntry(
                tool: .make(
                    "browser_read", title: "Read the Web",
                    description: """
                        Uses Safari on the Mac, signed in as the Mac's owner, in Claude's own window. With url: \
                        opens that page (new_tab for a new tab). With back: goes back. With tab: switches to that \
                        tab. With nothing: reads the page showing. Answers with the page's text and the links, \
                        buttons, and fields on it, each with a reference like e12 for browser_act. Long pages come \
                        in parts; pass offset to read on. tabs: lists the tabs. screenshot: shows the window as an \
                        image (needs the Mac unlocked with its screen on).
                        """,
                    input: [
                        "url": .stringParam("A page to open"),
                        "new_tab": .boolParam("With url: open it in a new tab"),
                        "back": .boolParam("Go back to the previous page"),
                        "tab": .integerParam("Switch to this tab number"),
                        "tabs": .boolParam("List the tabs"),
                        "screenshot": .boolParam("Show the window as an image"),
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

    static let actions = ["click", "type", "script"]

    static func writeTools(browser: SafariBrowser) -> [ToolEntry] {
        let ops = Operations(writeOperations(browser: browser))
        return [
            ToolEntry(
                tool: .make(
                    "browser_act", title: "Act on the Page",
                    description: """
                        Acts on the page showing in Claude's Safari window, then answers with the page. action: \
                        click (ref: a link or button), type (ref: a field, text; or a list and the option's \
                        text; submit sends the form), script (code: JavaScript run in the page; its result is \
                        returned).
                        """,
                    input: [
                        "action": .enumParam(actions, "What to do"),
                        "ref": .stringParam("The element's reference from browser_read, like e12"),
                        "text": .stringParam("For type: the text, or the option to choose"),
                        "submit": .boolParam("For type: send the form afterwards"),
                        "code": .stringParam("For script: the JavaScript"),
                    ], required: ["action"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    let action = args["action"]?.stringValue
                    switch action {
                    case "click": return await ops.call("browser_click", args)
                    case "type": return await ops.call("browser_type", args)
                    case "script": return await ops.call("browser_script", args)
                    default: return .unknown("action", action, allowed: actions)
                    }
                })
        ]
    }
}
